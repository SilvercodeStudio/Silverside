import ArgumentParser
import CDRipDarwin
import CDRipKit
import Foundation

struct Repair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check ripped WAV files against CUETools DB, and repair them with its repair data.")

    @OptionGroup var deviceOptions: DeviceOptions

    @Option(help: "The disc's CTDB TOC, such as 0:31400:58160:295575, in place of reading the disc.")
    var toc: String?

    @Option(
        name: .shortAndLong,
        help: """
            A folder with ripped "Track NN.wav" files. Give it more than once to pool several rips of the disc: \
            sectors where they disagree are suspect, and help the repair.
            """)
    var input: [String]

    @Option(
        name: .shortAndLong, help: "The folder for repaired files. Default: the input folder's name with \" repaired\"."
    )
    var output: String?

    @Option(help: "Rounds of re-reads for columns that cannot be repaired, when the disc is in a drive.")
    var rereadRounds = 4

    @Option(help: "The drive's read offset for re-reads. Default: from the drive's profile.")
    var offset: Int?

    /// Try at most this many shifts for each entry, fewest errors in column 0 first.
    static let shiftsPerEntry = 3

    /// Re-read the suspect samples of at most this many columns that cannot be repaired.
    static let maximumColumnsToReread = 512

    /// With the disc in a drive, read a track that does not match AccurateRip until it has this many versions.
    static let versionsToRead = 3

    /// Search for shifts with many errors in column 0 only for this many entries, the
    /// largest first. That search is slow, and small entries rarely help.
    static let entriesWithFullSearch = 3

    func run() async throws {
        let toc =
            try self.toc.map { try TOC(ctdbTOCString: $0) } ?? IOKitDrive(bsdName: deviceOptions.bsdName()).readTOC()
        let audioTracks = toc.audioTracks
        guard !audioTracks.isEmpty else { throw CommandError("This disc has no audio tracks.") }
        guard let firstInput = input.first else { throw ValidationError("Give at least one --input folder.") }
        let folders = input.map { URL(filePath: $0, directoryHint: .isDirectory) }
        // Look everything up first, so that a network problem shows before long re-reads.
        let records = try await AccurateRipRecord.download(for: toc.accurateRipDiscID)
        let entries = try await CTDBEntry.lookup(toc).sorted { $0.confidence > $1.confidence }
        guard !entries.isEmpty else { throw CommandError("This disc is not in CUETools DB.") }

        // Re-reads need the disc: not with --toc.
        let reader = self.toc == nil ? try rereader(toc: toc) : nil

        // Every version of every track, and the disc as the first versions give it, which
        // is enough to find the tracks that match AccurateRip at another pressing's offset.
        var versions = [[[UInt32]]]()
        for track in audioTracks {
            let length = toc.sectorRange(of: track).count * CDDA.samplesPerSector
            let name = String(format: "Track %02d.wav", track.number)
            let found = folders.compactMap { try? WAVFile.read($0.appending(path: name)) }.filter { $0.count == length }
            guard !found.isEmpty else { throw CommandError("No folder has \(name) with the TOC's length.") }
            versions.append(found)
        }
        var trackStarts = [Int]()
        var firstVersions = [UInt32]()
        for trackVersions in versions {
            trackStarts.append(firstVersions.count)
            firstVersions += trackVersions[0]
        }

        // The disc's audio, from the first audio track to the lead-out. For each track,
        // use a version that matches AccurateRip, at any offset, if there is one. Otherwise
        // take the sectors where the versions disagree as suspect.
        var audio = [UInt32]()
        var suspects = [Range<Int>]()
        var alternatives = [Int: [UInt32]]()
        for (index, track) in audioTracks.enumerated() {
            let length = versions[index][0].count
            let edges = (isFirst: index == 0, isLast: index == audioTracks.count - 1)
            let known = records.compactMap { $0.tracks.indices.contains(index) ? $0.tracks[index] : nil }
            let accurate = versions[index].first { samples in
                let checksum = AccurateRipAccumulator.checksum(
                    of: samples.span, isFirstTrack: edges.isFirst, isLastTrack: edges.isLast)
                if case .accurate = TrackRipper.verification(of: checksum, known: known) { return true }
                return false
            }
            if let accurate {
                audio += accurate
                print(String(format: "Track %2d  accurate in AccurateRip", track.number))
                continue
            }
            if let shift = Self.otherPressingShift(
                of: firstVersions, start: trackStarts[index], length: length, edges: edges, known: known)
            {
                audio += versions[index][0]
                print(
                    String(format: "Track %2d  free of errors: matches another pressing at ", track.number)
                        + Rip.signed(shift))
                continue
            }
            // With the disc in a drive, read a track that has few versions again, so that
            // the reads can disagree where the disc is damaged.
            var trackVersions = versions[index]
            if let reader, trackVersions.count < Self.versionsToRead {
                for _ in trackVersions.count..<Self.versionsToRead {
                    flushCache(reader: reader, awayFrom: toc.sectorRange(of: track), toc: toc)
                    trackVersions.append(try reader.readTrack(track))
                }
            }
            // Where the versions disagree, use the value that most of them have (the earlier
            // folder's on a tie), and take the sample as suspect. Only those samples are
            // suspect: whole sectors would give each CTDB column more suspects than its
            // syndromes can take.
            let first = trackVersions[0]
            var chosen = first
            var disagreeing = 0
            var runStart: Int?
            for sample in 0...length {
                let differs = sample < length && trackVersions.dropFirst().contains { $0[sample] != first[sample] }
                if differs {
                    disagreeing += 1
                    if runStart == nil { runStart = sample }
                    var counts = [UInt32: Int]()
                    for version in trackVersions { counts[version[sample], default: 0] += 1 }
                    let most = counts.values.max()!
                    chosen[sample] = trackVersions.first { counts[$0[sample]] == most }![sample]
                    alternatives[audio.count + sample] = counts.keys.filter { $0 != chosen[sample] }
                } else if let start = runStart {
                    suspects.append((audio.count + start)..<(audio.count + sample))
                    runStart = nil
                }
            }
            audio += chosen
            print(
                String(format: "Track %2d  ", track.number)
                    + "\(trackVersions.count) versions, \(disagreeing) samples where they disagree")
        }
        let folder = URL(filePath: firstInput, directoryHint: .isDirectory)
        let layout = CTDBLayout(toc: toc)
        guard audio.count == layout.sampleCount else { throw CommandError("The files do not cover the whole disc.") }

        print("CTDB: \(entries.count) entries, up to \(entries[0].confidence) submissions")

        let crc = CTDB.discCRC(of: audio, layout: layout)
        if let entry = entries.first(where: { $0.crc32 == crc }) {
            print("Verified: the rip matches entry \(entry.id) (\(entry.confidence) submissions), with no errors.")
            return
        }

        print("Finding the shift between the rip and each entry...")
        let count = min(16, entries.map(\.syndromeCount).max() ?? 0)
        guard count > 0 else { throw CommandError("No entry has syndromes to find the shift with.") }
        let candidates = CTDB.column0Syndromes(of: audio, layout: layout, count: count)

        // The offsets at which tracks match AccurateRip are other pressings' alignments, so
        // an entry may be stored at one of them. A shift where any of the entry's track CRCs
        // matches is right, even if column 0 has too many errors to find it.
        let hints = Self.accurateRipShifts(of: audio, toc: toc, trackStarts: trackStarts, records: records)
        entries: for (rank, entry) in entries.enumerated()
        where entry.syndromeCount > 0 && entry.column0Syndromes.count == entry.syndromeCount {
            var matches = [CTDB.ShiftMatch]()
            if entry.trackCRCs.count == audioTracks.count {
                for shift in hints where layout.shifts.contains(shift) {
                    let trackCRCs = CTDB.trackCRCs(of: audio, toc: toc, layout: layout, shift: shift)
                    if zip(trackCRCs, entry.trackCRCs).contains(where: { $0 == $1 }) {
                        matches.append(CTDB.ShiftMatch(shift: shift, errors: 0))
                    }
                }
            }
            for match in CTDB.shifts(
                matching: entry.column0Syndromes, in: candidates, layout: layout,
                fullSearch: rank < Self.entriesWithFullSearch)
            where !matches.contains(where: { $0.shift == match.shift }) {
                matches.append(match)
            }
            for match in matches.prefix(Self.shiftsPerEntry) {
                let name = "entry \(entry.id) (\(entry.confidence) submissions) at shift \(Rip.signed(match.shift))"
                if CTDB.discCRC(of: audio, layout: layout, shift: match.shift) == entry.crc32 {
                    print("Verified: the rip matches \(name), with no errors.")
                    return
                }
                guard entry.hasParity else { continue }
                print("Repairing with \(name)...")
                let reference = try await entry.downloadRepairData()
                var quietRounds = 0
                rounds: for round in 0...(reader == nil ? 0 : rereadRounds) {
                    var repaired = audio
                    let result = CTDB.repair(
                        &repaired, layout: layout, shift: match.shift, reference: reference,
                        count: entry.syndromeCount, crc: entry.crc32, suspects: suspects, alternatives: alternatives)
                    var unproved = [CTDB.Change]()
                    switch result {
                    case .noErrors:
                        print("  No errors.")
                        return
                    case .repaired(let changed):
                        try report(
                            changed: changed, repaired: repaired, toc: toc, trackStarts: trackStarts, folder: folder,
                            records: records)
                        return
                    case .uncorrectable(let columns, let columnsWithErrors, let checked, let changes):
                        let part = checked < CTDBLayout.stride ? " (stopped after \(checked) columns)" : ""
                        print(
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
                            let found = try reread(samples, of: audio, reader: reader, toc: toc, into: &alternatives)
                            let sectors = Set(samples.map { $0 / CDDA.samplesPerSector }).count
                            print("  Re-read \(sectors) sectors: \(found) new versions.")
                            quietRounds = found == 0 ? quietRounds + 1 : 0
                            if quietRounds < 2 { continue rounds }
                        }
                        unproved = changes
                    case .failedCheck(let columnsWithErrors, let changes):
                        print("  The repair did not give the entry's CRC (\(columnsWithErrors) columns with errors).")
                        unproved = changes
                    }
                    // Some corrections are missing or wrong. Keep those in tracks that a CRC then proves right.
                    if try keepProvedTracks(
                        unproved, of: audio, entry: entry, shift: match.shift, toc: toc, layout: layout,
                        trackStarts: trackStarts, folder: folder, records: records)
                    {
                        return
                    }
                    break entries
                }
            }
        }
        print("Could not verify or repair the rip with any entry.")
    }

    /// The shift at which a track matches AccurateRip, other than 0: by its sector 450
    /// checksum first, then its whole checksum. Such a track is free of errors.
    static func otherPressingShift(
        of audio: [UInt32], start: Int, length: Int, edges: (isFirst: Bool, isLast: Bool),
        known: [AccurateRipRecord.Track]
    ) -> Int? {
        let margin = 5 * CDDA.samplesPerSector
        guard !known.isEmpty, length >= 451 * CDDA.samplesPerSector, start >= margin,
            start + length + margin <= audio.count
        else { return nil }
        let window = Array(audio[(start - margin)..<(start + length + margin)])
        let found = AccurateRipOffsetFinder.frame450Offsets(
            matching: Set(known.map(\.frame450Checksum)), in: window, trackLength: length, margin: margin)
        guard found.count <= 16 else { return nil }
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
        let margin = 5 * CDDA.samplesPerSector
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
            if found.count <= 16 { shifts.formUnion(found) }
        }
        return shifts.sorted { abs($0) < abs($1) }
    }

    /// Applies `changes`, and keeps them only in the tracks whose CTDB track CRC then
    /// matches the entry's. Writes the result if any track was repaired. Returns true then.
    private func keepProvedTracks(
        _ changes: [CTDB.Change], of audio: [UInt32], entry: CTDBEntry, shift: Int, toc: TOC, layout: CTDBLayout,
        trackStarts: [Int], folder: URL, records: [AccurateRipRecord]
    ) throws -> Bool {
        guard !changes.isEmpty, entry.trackCRCs.count == toc.audioTracks.count else { return false }
        var partial = audio
        for change in changes { partial[change.sample] ^= change.mask }
        let trackCRCs = CTDB.trackCRCs(of: partial, toc: toc, layout: layout, shift: shift)
        var kept = [Int]()
        var proved = [Int]()
        for (index, trackCRC) in trackCRCs.enumerated() {
            let start = trackStarts[index]
            let end = index + 1 < trackStarts.count ? trackStarts[index + 1] : partial.count
            let inTrack = changes.filter { (start..<end).contains($0.sample) }
            if trackCRC == entry.trackCRCs[index] {
                kept += inTrack.map(\.sample)
                if !inTrack.isEmpty { proved.append(toc.audioTracks[index].number) }
            } else {
                // Undo this track's corrections: they are not proved.
                for change in inTrack { partial[change.sample] ^= change.mask }
            }
        }
        guard !kept.isEmpty else { return false }
        print("  Keeping the corrections in tracks \(proved), whose CTDB track CRCs then match.")
        try report(
            changed: Array(Set(kept)).sorted(), repaired: partial, toc: toc, trackStarts: trackStarts, folder: folder,
            records: records)
        return true
    }

    /// An offset-corrected reader for the disc in the drive, with the drive's offset.
    private func rereader(toc: TOC) throws -> AudioReader {
        let bsdName = try deviceOptions.bsdName()
        let drive = try IOKitDrive(bsdName: bsdName)
        var readOffset = offset
        if readOffset == nil, let device = OpticalDrive.all().first(where: { $0.discBSDName == bsdName }) {
            readOffset = try DriveProfileStore().profile(
                vendor: device.vendor, product: device.product, revision: device.revision
            ).offset?.value
        }
        guard let readOffset else { throw CommandError("The drive's read offset is not known. Give it with --offset.") }
        return AudioReader(drive: drive, toc: toc, readOffset: readOffset, canOverread: false)
    }

    /// Reads 4,000 sectors away from `sectors`: more than a drive's cache holds.
    private func flushCache(reader: AudioReader, awayFrom sectors: Range<Int>, toc: TOC) {
        let far = sectors.lowerBound > toc.leadOutLBA / 2 ? 0 : max(0, toc.leadOutLBA - 4000)
        for lba in stride(from: far, to: min(far + 4000, toc.leadOutLBA), by: 26) {
            _ = try? reader.drive.readAudioSectors(at: lba, count: min(26, toc.leadOutLBA - lba))
        }
    }

    /// Re-reads the sectors that hold `samples` (indexes in the disc's audio), after
    /// reading elsewhere so the drive's cache holds none of them. Adds each value that is
    /// not the one in `audio`, and not yet known, to `alternatives`. Returns how many it added.
    private func reread(
        _ samples: [Int], of audio: [UInt32], reader: AudioReader, toc: TOC, into alternatives: inout [Int: [UInt32]]
    ) throws -> Int {
        let firstSample = (toc.audioTracks.first?.startLBA ?? 0) * CDDA.samplesPerSector
        let sectors = Set(samples.map { $0 / CDDA.samplesPerSector }).sorted()
        let wanted = Set(samples)
        var added = 0
        for _ in 0..<4 {
            let first = sectors.first ?? 0
            flushCache(reader: reader, awayFrom: first..<(first + 1), toc: toc)
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

    /// Writes the repaired tracks, and checks them against AccurateRip, which does not depend on CTDB.
    private func report(
        changed: [Int], repaired: [UInt32], toc: TOC, trackStarts: [Int], folder: URL, records: [AccurateRipRecord]
    ) throws {
        let audioTracks = toc.audioTracks
        let destination = URL(
            filePath: output ?? folder.standardizedFileURL.path + " repaired", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        print("  Repaired \(changed.count) samples. Files: \(destination.path)")
        for (index, track) in audioTracks.enumerated() {
            let start = trackStarts[index]
            let end = index + 1 < trackStarts.count ? trackStarts[index + 1] : repaired.count
            let samples = Array(repaired[start..<end])
            try WAVFile.write(samples, to: destination.appending(path: String(format: "Track %02d.wav", track.number)))
            let fixes = changed.filter { (start..<end).contains($0) }.count
            let checksum = AccurateRipAccumulator.checksum(
                of: samples.span, isFirstTrack: index == 0, isLastTrack: index == audioTracks.count - 1)
            let known = records.compactMap { $0.tracks.indices.contains(index) ? $0.tracks[index] : nil }
            var line = String(format: "  Track %2d  %6d samples repaired  ", track.number, fixes)
            switch TrackRipper.verification(of: checksum, known: known) {
            case .accurate(let v1, let v2): line += "AccurateRip: accurate (v1 \(v1), v2 \(v2))"
            case .notAccurate: line += "AccurateRip: not accurate"
            case .notChecked: line += "AccurateRip: not in the database"
            }
            print(line)
        }
    }
}
