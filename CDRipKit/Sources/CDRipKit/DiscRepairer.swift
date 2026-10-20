/// One track's audio for a CTDB repair: the samples to start from, and the other
/// values that reads gave where they disagree.
public struct TrackAudio: Sendable {
    public var samples: [UInt32]
    /// Other values for samples, by index in the track. These samples are suspect.
    public var alternatives: [Int: [UInt32]]

    public init(samples: [UInt32], alternatives: [Int: [UInt32]] = [:]) {
        self.samples = samples
        self.alternatives = alternatives
    }

    /// From several reads of a track, all of the same length. Where they disagree, a
    /// sample gets the value that most reads have (the earlier read's on a tie), and the
    /// other values are its alternatives. Only those samples are suspect: whole sectors
    /// would give each CTDB column more suspects than its syndromes can take.
    public init(versions: [[UInt32]]) {
        let first = versions[0]
        var chosen = first
        var alternatives = [Int: [UInt32]]()
        for sample in first.indices where versions.dropFirst().contains(where: { $0[sample] != first[sample] }) {
            var counts = [UInt32: Int]()
            for version in versions { counts[version[sample], default: 0] += 1 }
            let most = counts.values.max()!
            chosen[sample] = versions.first { counts[$0[sample]] == most }![sample]
            alternatives[sample] = Self.others(versions.map { $0[sample] }, than: chosen[sample])
        }
        self.init(samples: chosen, alternatives: alternatives)
    }

    /// From a secure rip: its samples, with the other versions of its suspect sectors.
    public init(_ rip: SecureTrackRip) {
        var alternatives = [Int: [UInt32]]()
        for (sector, versions) in rip.sectorVersions {
            for offset in 0..<CDDA.samplesPerSector {
                let sample = sector * CDDA.samplesPerSector + offset
                let others = Self.others(versions.map { $0[offset] }, than: rip.samples[sample])
                if !others.isEmpty { alternatives[sample] = others }
            }
        }
        self.init(samples: rip.samples, alternatives: alternatives)
    }

    /// The values other than `chosen`, once each, in the order they come.
    private static func others(_ values: [UInt32], than chosen: UInt32) -> [UInt32] {
        var others = [UInt32]()
        for value in values where value != chosen && !others.contains(value) { others.append(value) }
        return others
    }
}

public enum DiscRepairError: Error, Equatable, CustomStringConvertible {
    /// The tracks do not cover the disc from the first audio track to the lead-out.
    case incompleteAudio

    public var description: String {
        switch self {
        case .incompleteAudio: "The tracks do not cover the whole disc."
        }
    }
}

/// Verifies a rip of a whole disc with CUETools DB, and repairs it with an entry's repair data.
///
/// For each entry, the most submissions first, the repairer finds the shift between the
/// rip and the entry, then decodes each column with the entry's syndromes. Suspect samples
/// (where reads disagree) are erasures, and their other values are choices. With the disc
/// in a drive, it re-reads the samples of columns that have too many errors. When no entry
/// repairs the whole disc, it keeps the corrections in tracks whose CTDB track CRC then matches.
public struct DiscRepairer {
    public enum Outcome: Equatable, Sendable {
        /// The rip matches the entry's CRC with no changes.
        case verified(entry: CTDBEntry, shift: Int)
        /// The repaired rip matches the entry's CRC.
        case repaired(entry: CTDBEntry, shift: Int, changedSamples: [Int])
        /// No entry repairs the whole rip. The corrections are kept in `tracks` (track
        /// numbers) only, because their CTDB track CRCs then match the entry's.
        case partlyRepaired(entry: CTDBEntry, shift: Int, tracks: [Int], changedSamples: [Int])
        /// No entry verifies or repairs the rip.
        case notVerified
    }

    public struct Result: Sendable {
        public var outcome: Outcome
        /// The disc's audio, from the first audio track to the lead-out, with the corrections.
        public var audio: [UInt32]
        /// Where each audio track starts in `audio`.
        public var trackStarts: [Int]
        /// For each audio track, the most submissions of an entry whose track CRC matches
        /// the track, at shift 0 or at the outcome's shift. 0 if none matches.
        public var trackConfidences: [Int]
        /// The number of entries that match the rip's alignment, but have no repair data.
        public var entriesWithoutRepairData = 0

        /// The samples of one audio track, by its index among the audio tracks.
        public func samples(ofTrack index: Int) -> [UInt32] {
            Array(audio[trackRange(index)])
        }

        /// The number of changed samples in one audio track.
        public func changedSamples(inTrack index: Int) -> Int {
            let range = trackRange(index)
            switch outcome {
            case .repaired(_, _, let changed), .partlyRepaired(_, _, _, let changed):
                return changed.filter(range.contains).count
            case .verified, .notVerified:
                return 0
            }
        }

        func trackRange(_ index: Int) -> Range<Int> {
            trackStarts[index]..<(index + 1 < trackStarts.count ? trackStarts[index + 1] : audio.count)
        }
    }

    public let toc: TOC
    public let records: [AccurateRipRecord]
    /// The disc's CTDB entries, the most submissions first.
    public let entries: [CTDBEntry]
    /// A reader for the disc, for re-reads of columns that have too many errors. Nil gives no re-reads.
    public var reader: AudioReader?
    /// Rounds of re-reads for the columns that cannot be repaired.
    public var rereadRounds = 4
    /// Receives a line for each step, for people to read.
    public var log: (String) -> Void = { _ in }
    /// Gets an entry's repair data. Tests replace the download.
    public var repairData: (CTDBEntry) async throws -> [UInt16] = { try await $0.downloadRepairData() }

    /// Try at most this many shifts for each entry, fewest errors in column 0 first.
    static let shiftsPerEntry = 3

    /// Re-read the suspect samples of at most this many columns that cannot be repaired.
    static let maximumColumnsToReread = 512

    /// Search for shifts with many errors in column 0 only for this many entries, the
    /// largest first. That search is slow, and small entries rarely help.
    static let entriesWithFullSearch = 3

    public init(toc: TOC, records: [AccurateRipRecord], entries: [CTDBEntry], reader: AudioReader? = nil) {
        self.toc = toc
        self.records = records
        self.entries = entries.sorted { $0.confidence > $1.confidence }
        self.reader = reader
    }

    /// Verifies the rip and, if `repairing`, repairs it. Without `repairing`, only CRCs
    /// are checked, at shift 0 and at each shift where column 0 matches an entry exactly.
    public func repair(_ tracks: [TrackAudio], repairing: Bool = true) async throws -> Result {
        var audio = [UInt32]()
        var trackStarts = [Int]()
        var alternatives = [Int: [UInt32]]()
        for track in tracks {
            trackStarts.append(audio.count)
            for (sample, values) in track.alternatives { alternatives[audio.count + sample] = values }
            audio += track.samples
        }
        let layout = CTDBLayout(toc: toc)
        guard tracks.count == toc.audioTracks.count, audio.count == layout.sampleCount else {
            throw DiscRepairError.incompleteAudio
        }
        let suspects = Self.ranges(of: alternatives.keys.sorted())
        var result = Result(outcome: .notVerified, audio: audio, trackStarts: trackStarts, trackConfidences: [])
        // Entries that match the rip's alignment but have no repair data: often single
        // submissions, each with its own errors.
        var withoutRepairData = Set<Int>()

        func finish(_ outcome: Outcome, audio: [UInt32]? = nil) -> Result {
            result.outcome = outcome
            result.entriesWithoutRepairData = withoutRepairData.count
            if let audio { result.audio = audio }
            result.trackConfidences = trackConfidences(of: result.audio, layout: layout, outcome: outcome)
            return result
        }

        let crc = CTDB.discCRC(of: audio, layout: layout)
        if let entry = entries.first(where: { $0.crc32 == crc }) { return finish(.verified(entry: entry, shift: 0)) }
        let count = min(16, entries.map(\.syndromeCount).max() ?? 0)
        guard count > 0 else { return finish(.notVerified) }

        log("Finding the shift between the rip and each entry...")
        let candidates = CTDB.column0Syndromes(of: audio, layout: layout, count: count)
        // The offsets at which tracks match AccurateRip are other pressings' alignments, so
        // an entry may be stored at one of them. A shift where any of the entry's track CRCs
        // matches is right, even if column 0 has too many errors to find it.
        let hints = Self.accurateRipShifts(of: audio, toc: toc, trackStarts: trackStarts, records: records)
        // The track CRCs at each hint shift, once: they are the same for every entry.
        let hintCRCs = hints.filter(layout.shifts.contains).map {
            (shift: $0, crcs: CTDB.trackCRCs(of: audio, toc: toc, layout: layout, shift: $0))
        }
        var best: (entry: CTDBEntry, shift: Int, tracks: [Int], changed: [Int], audio: [UInt32])?
        entries: for (rank, entry) in entries.enumerated()
        where entry.syndromeCount > 0 && entry.column0Syndromes.count == entry.syndromeCount {
            var matches = [CTDB.ShiftMatch]()
            if entry.trackCRCs.count == tracks.count {
                for (shift, trackCRCs) in hintCRCs where zip(trackCRCs, entry.trackCRCs).contains(where: { $0 == $1 }) {
                    matches.append(CTDB.ShiftMatch(shift: shift, errors: 0))
                }
            }
            for match in CTDB.shifts(
                matching: entry.column0Syndromes, in: candidates, layout: layout,
                fullSearch: repairing && rank < Self.entriesWithFullSearch)
            where !matches.contains(where: { $0.shift == match.shift }) {
                matches.append(match)
            }
            for match in matches.prefix(Self.shiftsPerEntry) {
                let name = "entry \(entry.id) (\(entry.confidence) submissions) at shift \(Self.signed(match.shift))"
                if CTDB.discCRC(of: audio, layout: layout, shift: match.shift) == entry.crc32 {
                    return finish(.verified(entry: entry, shift: match.shift))
                }
                guard repairing, entry.hasParity else {
                    if match.errors == 0 && !entry.hasParity { withoutRepairData.insert(entry.id) }
                    continue
                }
                log("Repairing with \(name)...")
                let reference = try await repairData(entry)
                var quietRounds = 0
                rounds: for round in 0...(reader == nil ? 0 : rereadRounds) {
                    var repaired = audio
                    let repair = CTDB.repair(
                        &repaired, layout: layout, shift: match.shift, reference: reference,
                        count: entry.syndromeCount, crc: entry.crc32, suspects: suspects, alternatives: alternatives)
                    var unproved = [CTDB.Change]()
                    switch repair {
                    case .noErrors:
                        return finish(.verified(entry: entry, shift: match.shift))
                    case .repaired(let changed):
                        return finish(
                            .repaired(entry: entry, shift: match.shift, changedSamples: changed), audio: repaired)
                    case .uncorrectable(let columns, let columnsWithErrors, let checked, let changes):
                        let part = checked < CTDBLayout.stride ? " (stopped after \(checked) columns)" : ""
                        log(
                            "  Cannot repair: \(columns.count) of \(columnsWithErrors) columns with errors have too many"
                                + part + (columns.count <= 8 ? ": columns \(columns)" : "") + ".")
                        // Most columns repaired: this is the entry's shift, so re-read, and try no other shift.
                        guard checked == CTDBLayout.stride, columns.count <= Self.maximumColumnsToReread else {
                            break rounds
                        }
                        if let reader, round < rereadRounds {
                            let samples = columns.flatMap {
                                CTDB.suspectSamples(
                                    inColumn: $0, suspects: suspects, layout: layout, shift: match.shift)
                            }
                            let found = reread(samples, of: audio, reader: reader, into: &alternatives)
                            let sectors = Set(samples.map { $0 / CDDA.samplesPerSector }).count
                            log("  Re-read \(sectors) sectors: \(found) new versions.")
                            quietRounds = found == 0 ? quietRounds + 1 : 0
                            if quietRounds < 2 { continue rounds }
                        }
                        unproved = changes
                    case .failedCheck(let columnsWithErrors, let changes):
                        log("  The repair did not give the entry's CRC (\(columnsWithErrors) columns with errors).")
                        unproved = changes
                    }
                    // Some corrections are missing or wrong. Keep the best set of tracks that a CRC
                    // then proves right, and try the next entry: it may repair more.
                    let proved = provedTracks(
                        unproved, of: audio, entry: entry, shift: match.shift, layout: layout,
                        trackStarts: trackStarts)
                    if proved.tracks.count > (best?.tracks.count ?? 0) {
                        best = (entry, match.shift, proved.tracks, proved.changed, proved.audio)
                    }
                    continue entries
                }
            }
        }
        if let best {
            return finish(
                .partlyRepaired(
                    entry: best.entry, shift: best.shift, tracks: best.tracks, changedSamples: best.changed),
                audio: best.audio)
        }
        return finish(.notVerified)
    }

    /// For each track, the most submissions of an entry whose track CRC matches.
    private func trackConfidences(of audio: [UInt32], layout: CTDBLayout, outcome: Outcome) -> [Int] {
        var shifts: Set<Int> = [0]
        switch outcome {
        case .verified(_, let shift), .repaired(_, let shift, _), .partlyRepaired(_, let shift, _, _):
            shifts.insert(shift)
        case .notVerified: break
        }
        var confidences = [Int](repeating: 0, count: toc.audioTracks.count)
        for shift in shifts {
            let crcs = CTDB.trackCRCs(of: audio, toc: toc, layout: layout, shift: shift)
            for entry in entries where entry.trackCRCs.count == crcs.count {
                for index in crcs.indices where crcs[index] == entry.trackCRCs[index] {
                    confidences[index] = max(confidences[index], entry.confidence)
                }
            }
        }
        return confidences
    }

    /// Applies `changes`, and keeps them only in the tracks whose CTDB track CRC then
    /// matches the entry's. Returns those tracks' numbers, the samples kept, and the audio.
    private func provedTracks(
        _ changes: [CTDB.Change], of audio: [UInt32], entry: CTDBEntry, shift: Int, layout: CTDBLayout,
        trackStarts: [Int]
    ) -> (tracks: [Int], changed: [Int], audio: [UInt32]) {
        guard !changes.isEmpty, entry.trackCRCs.count == toc.audioTracks.count else { return ([], [], audio) }
        var partial = audio
        for change in changes { partial[change.sample] ^= change.mask }
        let trackCRCs = CTDB.trackCRCs(of: partial, toc: toc, layout: layout, shift: shift)
        var kept = Set<Int>()
        var proved = [Int]()
        for (index, trackCRC) in trackCRCs.enumerated() {
            let start = trackStarts[index]
            let end = index + 1 < trackStarts.count ? trackStarts[index + 1] : partial.count
            let inTrack = changes.filter { (start..<end).contains($0.sample) }
            if trackCRC == entry.trackCRCs[index] && !inTrack.isEmpty {
                kept.formUnion(inTrack.map(\.sample))
                proved.append(toc.audioTracks[index].number)
            } else {
                // Undo this track's corrections: they are not proved.
                for change in inTrack { partial[change.sample] ^= change.mask }
            }
        }
        return (proved, kept.sorted(), partial)
    }

    /// Re-reads the sectors that hold `samples` (indexes in the disc's audio), after
    /// reading elsewhere so the drive's cache holds none of them. Adds each value that is
    /// not the one in `audio`, and not yet known, to `alternatives`. Returns how many it added.
    private func reread(
        _ samples: [Int], of audio: [UInt32], reader: AudioReader, into alternatives: inout [Int: [UInt32]]
    ) -> Int {
        let firstLBA = toc.audioTracks.first?.startLBA ?? 0
        let firstSample = firstLBA * CDDA.samplesPerSector
        let sectors = Set(samples.map { $0 / CDDA.samplesPerSector }).sorted()
        let wanted = Set(samples)
        var added = 0
        for _ in 0..<4 {
            let first = firstLBA + (sectors.first ?? 0)
            reader.flushCache(awayFrom: first..<(first + 1))
            for sector in sectors {
                let start = sector * CDDA.samplesPerSector
                guard
                    let read = try? reader.readSamples(
                        (firstSample + start)..<(firstSample + start + CDDA.samplesPerSector))
                else { continue }
                for (offset, value) in read.enumerated() where wanted.contains(start + offset) {
                    let sample = start + offset
                    if value != audio[sample] && !(alternatives[sample] ?? []).contains(value) {
                        alternatives[sample, default: []].append(value)
                        added += 1
                    }
                }
            }
        }
        return added
    }

    /// The shift at which a track matches AccurateRip, other than 0: by its sector 450
    /// checksum first, then its whole checksum. Such a track is free of errors.
    /// `audio` is the disc's audio, and the track starts at `start` in it.
    public static func otherPressingShift(
        of audio: [UInt32], start: Int, length: Int, edges: (isFirst: Bool, isLast: Bool),
        known: [AccurateRipRecord.Track]
    ) -> Int? {
        let margin = TrackRipper.margin
        guard !known.isEmpty, length >= 451 * CDDA.samplesPerSector, start >= margin,
            start + length + margin <= audio.count
        else { return nil }
        let window = Array(audio[(start - margin)..<(start + length + margin)])
        let found = AccurateRipOffsetFinder.frame450Offsets(
            matching: Set(known.map(\.frame450Checksum)), in: window, trackLength: length, margin: margin)
        guard found.count <= TrackRipper.maximumFrame450Matches else { return nil }
        for shift in found where shift != 0 {
            let shifted = Array(window[(margin + shift)..<(margin + shift + length)])
            let checksum = AccurateRipAccumulator.checksum(
                of: shifted.span, isFirstTrack: edges.isFirst, isLastTrack: edges.isLast)
            if case .accurate = TrackRipper.verification(of: checksum, known: known) { return shift }
        }
        return nil
    }

    /// The shifts, from the rip's alignment, at which a track matches AccurateRip: by
    /// each track's sector 450 checksum, as `AccurateRipOffsetFinder` finds them. Always has 0.
    static func accurateRipShifts(
        of audio: [UInt32], toc: TOC, trackStarts: [Int], records: [AccurateRipRecord]
    ) -> [Int] {
        var shifts: Set<Int> = [0]
        let margin = TrackRipper.margin
        for (index, track) in toc.audioTracks.enumerated() {
            let length = toc.sectorRange(of: track).count * CDDA.samplesPerSector
            let start = trackStarts[index]
            guard length >= 451 * CDDA.samplesPerSector, start >= margin, start + length + margin <= audio.count else {
                continue
            }
            let known = Set(
                records.compactMap { $0.tracks.indices.contains(index) ? $0.tracks[index].frame450Checksum : nil })
            let window = Array(audio[(start - margin)..<(start + length + margin)])
            let found = AccurateRipOffsetFinder.frame450Offsets(
                matching: known, in: window, trackLength: length, margin: margin)
            if found.count <= TrackRipper.maximumFrame450Matches { shifts.formUnion(found) }
        }
        return shifts.sorted { abs($0) < abs($1) }
    }

    /// Groups sorted indexes into ranges of consecutive indexes.
    static func ranges(of indexes: [Int]) -> [Range<Int>] {
        var ranges = [Range<Int>]()
        for index in indexes {
            if let last = ranges.last, index == last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<(index + 1)
            } else {
                ranges.append(index..<(index + 1))
            }
        }
        return ranges
    }

    static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }
}
