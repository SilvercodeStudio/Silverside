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
    /// For each suspect sector, its versions, most often read first. A CTDB repair uses
    /// them: where they disagree, the samples are suspect, and the other versions are choices.
    public var sectorVersions: [Int: [[UInt32]]] = [:]
    /// The number of reads of the whole track, the first rip included.
    public var fullReads = 1
    /// The number of rounds of re-reads of suspect sectors.
    public var rounds: Int
    /// The drive offsets at which the first read matches AccurateRip. See `TrackRip.matchingOffsets`.
    public var matchingOffsets: [Int]
    /// The shifts, in samples, of whole-track reads that lost their place (on a scratch,
    /// for example) and were left out. A read is shifted against the first read; if the
    /// first read is the shifted one, later reads agree with each other and replace it.
    public var shiftedReads: [Int] = []
    /// True if the first read lost its place, and a later read took its place.
    public var firstReadWasShifted = false
    /// The samples, by index in the track, that the first read flagged with C2 errors.
    /// Nil if the rip did not read C2 flags.
    public var c2Samples: [Int]?

    /// The samples, by index in the track, from sectors that the first read could not read.
    public var unreadableSamples: [Int] = []

    /// The sectors, counted from the track's start, that the first read could not read.
    public var unreadableSectors: [Int] {
        Array(Set(unreadableSamples.map { $0 / CDDA.samplesPerSector })).sorted()
    }

    /// The sectors, counted from the track's start, with C2 errors in the first read.
    public var c2Sectors: [Int]? { c2Samples.map { Array(Set($0.map { $0 / CDDA.samplesPerSector })).sorted() } }
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

    /// A run of at least this many sectors that differ from the first read is checked for a shift.
    public var shiftCheckSectors = 32

    /// Shifts of up to this many samples, either way, are found.
    public var maximumShift = 10 * CDDA.samplesPerSector

    /// Extra reads of the whole track when a read is shifted.
    public var maximumShiftedReads = 2

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
            rounds: 0, matchingOffsets: first.matchingOffsets, c2Samples: first.c2Samples,
            unreadableSamples: first.unreadableSamples)
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

        // The read that others are compared with: the first, unless it lost its place.
        var base = first.samples
        var versions = [Int: Versions]()
        // Sectors with C2 errors, or that could not be read, are suspect even if every read
        // agrees: re-read them too.
        func seedC2Sectors() {
            for index in (result.c2Sectors ?? []) + result.unreadableSectors where versions[index] == nil {
                versions[index] = Versions()
                versions[index]!.add(block(base, index))
            }
        }
        seedC2Sectors()
        var fullReads = 1
        func differingSectors(_ a: [UInt32], _ b: [UInt32]) -> [Int] {
            (0..<sectors.count).filter { a[($0 * size)..<(($0 + 1) * size)] != b[($0 * size)..<(($0 + 1) * size)] }
        }
        // Reads the whole track again and compares it with the base read. Returns true if
        // it shows suspect sectors that were not known. A read that lost its place is left
        // out and read again; two such reads that agree show that the base read lost its place.
        func readWholeTrack() throws -> Bool {
            var shiftedRead: [UInt32]?
            for _ in 0...maximumShiftedReads {
                reader.flushCache(awayFrom: sectors, count: cacheFlushSectors)
                let whole = try reader.read(start..<(start + sectors.count * size), withC2: false)
                let read = whole.samples
                // A sector that could not be read gives no version: its silence is not data.
                let unreadable = Set(whole.unreadable.map { $0 / size })
                fullReads += 1
                let differing = differingSectors(read, base)
                if let shift = Self.shift(
                    of: read, against: base, differing: differing, minimumRun: shiftCheckSectors,
                    maximum: maximumShift)
                {
                    if let previous = shiftedRead,
                        Self.shift(
                            of: read, against: previous, differing: differingSectors(read, previous),
                            minimumRun: shiftCheckSectors, maximum: maximumShift) == nil
                    {
                        // Two reads agree with each other, and not with the base: replace it.
                        // The base is the shifted read, not the read before this one.
                        result.shiftedReads[result.shiftedReads.count - 1] = -shift
                        result.firstReadWasShifted = true
                        base = read
                        versions = [:]
                        for index in differingSectors(read, previous) {
                            versions[index] = Versions()
                            versions[index]!.add(block(read, index))
                            versions[index]!.add(block(previous, index))
                        }
                        seedC2Sectors()
                        return !versions.isEmpty
                    }
                    result.shiftedReads.append(shift)
                    shiftedRead = read
                    continue
                }
                var foundNew = false
                for index in differing where versions[index] == nil && !unreadable.contains(index) {
                    versions[index] = Versions()
                    versions[index]!.add(block(base, index))
                    foundNew = true
                }
                for (index, _) in versions where !unreadable.contains(index) {
                    versions[index]!.add(block(read, index))
                }
                return foundNew
            }
            return false
        }

        let known = ripper.known(for: track)
        let edges = ripper.edges(of: track)
        // Two reads can be wrong in the same way, so a track that does not match
        // AccurateRip gets more full reads, while they show new suspect sectors.
        while try !readWholeTrack() && !known.isEmpty && fullReads < maximumFullReads {}
        if versions.isEmpty {
            result.samples = base
            result.status = known.isEmpty ? .consistent : .consistentButNotAccurate
            if result.firstReadWasShifted && !known.isEmpty {
                let checksum = AccurateRipAccumulator.checksum(
                    of: base.span, isFirstTrack: edges.isFirst, isLastTrack: edges.isLast)
                if case .accurate(let v1, let v2) = TrackRipper.verification(of: checksum, known: known) {
                    result.status = .accurate(v1Confidence: v1, v2Confidence: v2)
                }
            }
            result.fullReads = fullReads
            return result
        }

        var samples = base
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
            reader.flushCache(awayFrom: sectors, count: cacheFlushSectors)
            for run in Self.runs(of: versions.keys.sorted()) {
                let read = try reader.read(
                    (start + run.lowerBound * size)..<(start + run.upperBound * size), withC2: false)
                let unreadable = Set(read.unreadable.map { $0 / size + run.lowerBound })
                for index in run where versions[index] != nil && !unreadable.contains(index) {
                    versions[index]!.add(block(read.samples, index - run.lowerBound))
                }
            }
            quietRounds = versions.values.reduce(0) { $0 + $1.order.count } == versionCount ? quietRounds + 1 : 0
        }
        result.fullReads = fullReads
        result.versionCounts = versions.mapValues(\.order.count)
        result.sectorVersions = versions.mapValues(\.ranked)
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

    /// The shift, in samples, between `read` and `base` in the longest run of sectors
    /// where they differ: `read` at a position equals `base` that many samples on. Nil if
    /// the run is shorter than `minimumRun`, or if no single shift explains both the start
    /// and the end of the run. Damage changes data in place, so a shift does not explain it.
    static func shift(
        of read: [UInt32], against base: [UInt32], differing: [Int], minimumRun: Int, maximum: Int
    ) -> Int? {
        guard let run = DiscRepairer.ranges(of: differing).max(by: { $0.count < $1.count }), run.count >= minimumRun
        else { return nil }
        let size = CDDA.samplesPerSector
        func shift(at sector: Int) -> Int? {
            let start = sector * size
            let window = read[start..<(start + size)]
            // Silence, or a few repeating values, would match at many shifts.
            guard Set(window).count > 16 else { return nil }
            for distance in 1...maximum {
                for shift in [distance, -distance] where start + shift >= 0 && start + shift + size <= base.count {
                    if base[(start + shift)..<(start + shift + size)] == window { return shift }
                }
            }
            return nil
        }
        let atStart = run.prefix(8).lazy.compactMap(shift(at:)).first
        let atEnd = run.suffix(8).reversed().lazy.compactMap(shift(at:)).first
        guard let atStart, atStart == atEnd else { return nil }
        return atStart
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

extension AudioReader {
    /// Reads `count` sectors far from `sectors`, so the drive's cache holds none of them.
    /// The sectors read never overlap `sectors`: a read of a damaged sector there would
    /// count as one of its re-reads.
    public func flushCache(awayFrom sectors: Range<Int>, count: Int = 4000) {
        let before = 0..<sectors.lowerBound
        let after = sectors.upperBound..<toc.leadOutLBA
        let count = min(count, max(before.count, after.count))
        guard count > 0 else { return }
        // Read at the far end of the larger region.
        let start = before.count >= after.count ? 0 : after.upperBound - count
        for lba in stride(from: start, to: start + count, by: sectorsPerRead) {
            // A sector that cannot be read still moves the drive away; its data does not matter.
            _ = try? drive.readAudioSectors(at: lba, count: min(sectorsPerRead, start + count - lba))
        }
    }
}
