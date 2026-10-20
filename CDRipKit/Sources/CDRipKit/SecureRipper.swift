/// The result of a secure rip of one track.
public struct SecureTrackRip: Sendable {
    public enum Status: Equatable, Sendable {
        /// The track matches AccurateRip.
        case accurate(v1Confidence: Int, v2Confidence: Int)
        /// The track matches AccurateRip only at other offsets: the read is free of
        /// errors, and it is shifted against the pressings that the database has.
        case matchesOtherPressings(offsets: [Int])
        /// The disc is not in AccurateRip, and two reads agree on every sample.
        case consistent
        /// Two reads agree, but the track does not match AccurateRip. Either this
        /// pressing is not in the database, or the disc has an error that reads the same every time.
        case consistentButNotAccurate
        /// Some sectors read differently each time, and no choice of their data
        /// matches AccurateRip. `unresolvedSectors` lists them.
        case suspect
    }

    public var track: TOC.Track
    public var samples: [UInt32]
    public var status: Status
    /// The sectors, counted from the track's start (588 samples each), that read differently on different reads.
    public var suspectSectors: [Int]
    /// The suspect sectors whose data is still not known to be right.
    public var unresolvedSectors: [Int]
    /// For each suspect sector, the number of different versions that reads gave.
    public var versionCounts: [Int: Int] = [:]
    /// The number of reads of the whole track, the first rip included.
    public var fullReads = 1
    /// The number of rounds of re-reads of suspect sectors.
    public var rounds: Int
    /// The drive offsets at which the first read matches AccurateRip. See `TrackRip.matchingOffsets`.
    public var matchingOffsets: [Int]
}

/// Rips a track, and re-reads the sectors that read differently until the track
/// matches AccurateRip or the re-reads give up.
///
/// Damaged sectors can return different data on each read, and the drive's
/// cache returns the same copy until something else fills it. So before each
/// round of re-reads, the ripper reads sectors far from the track.
public struct SecureRipper {
    public let ripper: TrackRipper

    /// The most rounds of re-reads for one track.
    public var maximumRounds = 16

    /// Sectors to read far from the track before each round. This must be more
    /// than the drive's cache holds: 4 MB is about 1,800 sectors.
    public var cacheFlushSectors = 4000

    /// Without AccurateRip, a suspect sector is resolved when one version has been
    /// read this many more times than any other.
    public var agreement = 3

    /// The most combinations of sector versions to test against AccurateRip after each round.
    public var maximumCombinations = 1 << 16

    /// The most versions of one sector, by how often they were read, to use in combinations.
    public var maximumVersionsPerSector = 4

    /// After this many rounds in a row that give no new version of any sector,
    /// read the whole track again, or stop.
    public var roundsWithoutNewVersions = 4

    /// The most reads of the whole track, the first rip included, for a track that
    /// does not match AccurateRip.
    public var maximumFullReads = 4

    public init(ripper: TrackRipper) {
        self.ripper = ripper
    }

    /// The versions of one sector's data that reads gave, with how often each came back.
    struct Versions {
        var counts: [[UInt32]: Int] = [:]
        var order: [[UInt32]] = []

        mutating func add(_ samples: [UInt32]) {
            if counts[samples] == nil { order.append(samples) }
            counts[samples, default: 0] += 1
        }

        /// The versions, most often read first. Ties keep the order of the first read.
        var ranked: [[UInt32]] {
            order.enumerated().sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }
                .map(\.element)
        }

        /// True if the most frequent version leads every other by `margin` reads.
        func isDecided(by margin: Int) -> Bool {
            let sorted = counts.values.sorted(by: >)
            return sorted.count == 1 || sorted[0] - sorted[1] >= margin
        }
    }

    public func rip(_ track: TOC.Track) throws -> SecureTrackRip {
        let first = try ripper.rip(track)
        var result = SecureTrackRip(
            track: track, samples: first.samples, status: .consistent, suspectSectors: [], unresolvedSectors: [],
            rounds: 0, matchingOffsets: first.matchingOffsets)
        if case .accurate(let v1, let v2) = first.verification {
            result.status = .accurate(v1Confidence: v1, v2Confidence: v2)
            return result
        }
        if !first.matchingOffsets.isEmpty {
            result.status = .matchesOtherPressings(offsets: first.matchingOffsets)
            return result
        }

        let reader = ripper.reader
        let sectors = reader.toc.sectorRange(of: track)
        let start = sectors.lowerBound * CDDA.samplesPerSector
        let size = CDDA.samplesPerSector
        func block(_ samples: [UInt32], _ index: Int) -> [UInt32] {
            Array(samples[(index * size)..<((index + 1) * size)])
        }

        // Compares a new read of the whole track with the first read. Returns true
        // if it shows suspect sectors that were not known.
        var versions = [Int: Versions]()
        var fullReads = 1
        func readWholeTrack() throws -> Bool {
            try flushCache(awayFrom: sectors)
            let read = try reader.readSamples(start..<(start + sectors.count * size))
            fullReads += 1
            var foundNew = false
            for index in 0..<sectors.count {
                let data = block(read, index)
                if versions[index] != nil {
                    versions[index]!.add(data)
                } else if data != block(first.samples, index) {
                    versions[index] = Versions()
                    versions[index]!.add(block(first.samples, index))
                    versions[index]!.add(data)
                    foundNew = true
                }
            }
            return foundNew
        }

        let known = ripper.known(for: track)
        let edges = ripper.edges(of: track)
        // Two reads can be wrong in the same way, so a track that does not match
        // AccurateRip gets more full reads, while they show new suspect sectors.
        while try !readWholeTrack() && !known.isEmpty && fullReads < maximumFullReads {}
        if versions.isEmpty {
            result.status = first.verification == .notChecked ? .consistent : .consistentButNotAccurate
            result.fullReads = fullReads
            return result
        }

        var samples = first.samples
        var quietRounds = 0
        while true {
            // Use the most frequent version of each suspect sector.
            for (index, sectorVersions) in versions {
                samples.replaceSubrange((index * size)..<((index + 1) * size), with: sectorVersions.ranked[0])
            }
            if !known.isEmpty, let (matched, status) = match(samples, versions: versions, known: known, edges: edges) {
                result.samples = matched
                result.status = status
                result.unresolvedSectors = []
                break
            }
            let decided = known.isEmpty && versions.values.allSatisfy { $0.isDecided(by: agreement) }
            var stop = decided || result.rounds == maximumRounds
            if !stop && quietRounds == roundsWithoutNewVersions {
                // Re-reads give nothing new. Another full read may show suspect sectors not yet known.
                stop = try known.isEmpty || fullReads == maximumFullReads || !readWholeTrack()
                quietRounds = 0
                if !stop { continue }
            }
            if stop {
                result.samples = samples
                result.unresolvedSectors =
                    known.isEmpty
                    ? versions.filter { !$0.value.isDecided(by: agreement) }.map(\.key).sorted()
                    : versions.keys.sorted()
                result.status = result.unresolvedSectors.isEmpty ? .consistent : .suspect
                break
            }

            result.rounds += 1
            let versionCount = versions.values.reduce(0) { $0 + $1.order.count }
            try flushCache(awayFrom: sectors)
            for run in Self.runs(of: versions.keys.sorted()) {
                let read = try reader.readSamples((start + run.lowerBound * size)..<(start + run.upperBound * size))
                for index in run where versions[index] != nil {
                    versions[index]!.add(block(read, index - run.lowerBound))
                }
            }
            quietRounds = versions.values.reduce(0) { $0 + $1.order.count } == versionCount ? quietRounds + 1 : 0
        }
        result.fullReads = fullReads
        result.versionCounts = versions.mapValues(\.order.count)
        result.suspectSectors = versions.keys.sorted()
        return result
    }

    /// Finds a choice of versions for the suspect sectors that matches AccurateRip.
    /// `samples` holds the most frequent version of each. The checksums are sums,
    /// so each choice changes them by its sector's difference, and a combination
    /// can be tested without going through the whole track.
    private func match(
        _ samples: [UInt32], versions: [Int: Versions], known: [AccurateRipRecord.Track],
        edges: (isFirst: Bool, isLast: Bool)
    ) -> ([UInt32], SecureTrackRip.Status)? {
        let size = CDDA.samplesPerSector
        let base = AccurateRipAccumulator.checksum(
            of: samples.span, isFirstTrack: edges.isFirst, isLastTrack: edges.isLast)
        let knownChecksums = Set(known.map(\.checksum))
        func status(_ checksum: AccurateRipChecksum) -> SecureTrackRip.Status? {
            guard case .accurate(let v1, let v2) = TrackRipper.verification(of: checksum, known: known) else {
                return nil
            }
            return .accurate(v1Confidence: v1, v2Confidence: v2)
        }
        if let status = status(base) { return (samples, status) }

        // Each suspect sector with more than one version: the change that each of
        // its most frequent other versions makes.
        let choices: [(index: Int, versions: [[UInt32]], changes: [AccurateRipChecksum])] = versions.keys.sorted()
            .compactMap { index in
                let ranked = Array(versions[index]!.ranked.prefix(maximumVersionsPerSector))
                guard ranked.count > 1 else { return nil }
                func part(_ data: [UInt32]) -> AccurateRipChecksum {
                    AccurateRipAccumulator.contribution(
                        of: data.span, at: index * size + 1, sampleCount: samples.count,
                        isFirstTrack: edges.isFirst, isLastTrack: edges.isLast)
                }
                let used = part(ranked[0])
                return (index, ranked, ranked.map { part($0) - used })
            }
        guard !choices.isEmpty else { return nil }

        // Test the combinations that change one sector, then two, and so on, until
        // the budget is used. A track with few errors is most likely wrong in few sectors.
        var budget = maximumCombinations
        var chosen = [(choice: Int, version: Int)]()
        func search(from first: Int, changes: Int, checksum: AccurateRipChecksum) -> Bool {
            if changes == 0 {
                budget -= 1
                return (knownChecksums.contains(checksum.v1) || knownChecksums.contains(checksum.v2))
                    && status(checksum) != nil
            }
            for choice in first..<choices.count {
                for version in 1..<choices[choice].versions.count {
                    guard budget > 0 else { return false }
                    chosen.append((choice, version))
                    let changed = checksum + choices[choice].changes[version]
                    if search(from: choice + 1, changes: changes - 1, checksum: changed) { return true }
                    chosen.removeLast()
                }
            }
            return false
        }
        for changes in 1...choices.count where budget > 0 {
            guard search(from: 0, changes: changes, checksum: base) else { continue }
            var matched = samples
            var checksum = base
            for (choice, version) in chosen {
                let index = choices[choice].index
                matched.replaceSubrange((index * size)..<((index + 1) * size), with: choices[choice].versions[version])
                checksum = checksum + choices[choice].changes[version]
            }
            return (matched, status(checksum)!)
        }
        return nil
    }

    /// Reads sectors far from `sectors`, so the drive's cache holds none of them.
    /// The sectors read never overlap the track: a read of a damaged sector there
    /// would count as one of its re-reads.
    private func flushCache(awayFrom sectors: Range<Int>) throws {
        let reader = ripper.reader
        let before = 0..<sectors.lowerBound
        let after = sectors.upperBound..<reader.toc.leadOutLBA
        let count = min(cacheFlushSectors, max(before.count, after.count))
        guard count > 0 else { return }
        // Read at the far end of the larger region.
        let start = before.count >= after.count ? 0 : after.upperBound - count
        for lba in stride(from: start, to: start + count, by: reader.sectorsPerRead) {
            // A sector that cannot be read still moves the drive away; its data does not matter.
            _ = try? reader.drive.readAudioSectors(at: lba, count: min(reader.sectorsPerRead, start + count - lba))
        }
    }

    /// Groups sorted indexes into runs, joining runs with a gap of one, so the reads are fewer.
    static func runs(of indexes: [Int]) -> [Range<Int>] {
        var runs = [Range<Int>]()
        for index in indexes {
            if let last = runs.last, index <= last.upperBound + 1 {
                runs[runs.count - 1] = last.lowerBound..<(index + 1)
            } else {
                runs.append(index..<(index + 1))
            }
        }
        return runs
    }
}
