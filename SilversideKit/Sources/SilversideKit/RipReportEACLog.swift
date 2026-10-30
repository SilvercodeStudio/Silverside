import Foundation

extension RipReport {
    /// The rip as a log in the layout of Exact Audio Copy's, for people and tools that read
    /// those: the same sections, wording, and columns, from EAC 1.8's logs of real rips
    /// (2026-10-30). It names Silverside as the program that wrote it, and has no EAC log
    /// checksum: that signature is EAC's. Lines end in CR LF, as EAC's do.
    ///
    /// `folder` is where the rip's own files are, for the file names of a rip that is not
    /// encoded. A suspicious range ("0:01:05 - 0:01:07") and a data track's row are written as
    /// EAC most likely writes them; no log of EAC's showed them.
    public func eacStyleLog(folder: URL) -> String {
        let toc = try? TOC(ctdbTOCString: self.toc)
        var lines = [String]()
        lines.append(program)
        lines.append("")
        lines.append("Silverside extraction logfile from " + Self.eacDate(started ?? date))
        lines.append("")
        lines.append(eacTitle(toc: toc))
        lines.append("")
        // EAC pads the vendor to its 8 characters in the drive's inquiry data; a space keeps a
        // vendor of all 8 apart from the product.
        let vendor =
            drive.vendor.count < 8 ? drive.vendor.padding(toLength: 8, withPad: " ", startingAt: 0) : drive.vendor + " "
        lines.append("Used drive  : " + vendor + drive.product + "   Firmware: " + drive.revision)
        lines.append("")
        lines += eacSettings
        lines.append("")
        lines += eacOutputFormat
        lines += ["", ""]
        if let toc {
            lines += Self.eacTOC(toc)
            lines += ["", ""]
        }
        for track in tracks { lines += eacTrack(track, toc: toc, folder: folder) }
        lines.append("")
        lines += eacSummary
        lines += ["", "End of status report", "", ""]
        lines += eacCTDB(toc: toc)
        lines += ["", ""]
        lines += eacNotes
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    /// "30. October 2026, 11:12", as EAC writes the date, in English.
    static func eacDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d'. 'MMMM yyyy', 'H:mm"
        return formatter.string(from: date)
    }

    /// "Grateful Dead / Reckoning", with the disc of a set: "… (Disc 2)".
    private func eacTitle(toc: TOC?) -> String {
        guard let release else { return "Unknown Artist / Unknown Album" }
        let position = toc.flatMap { release.medium(for: $0)?.position }
        let disc = release.media.count > 1 ? position.map { " (Disc \($0))" } ?? "" : ""
        return "\(release.artist) / \(release.title)\(disc)"
    }

    private static func field(_ key: String, _ value: String, width: Int) -> String {
        key.padding(toLength: width, withPad: " ", startingAt: 0) + ": " + value
    }

    private var eacSettings: [String] {
        let yes = { (value: Bool) in value ? "Yes" : "No" }
        return [
            Self.field("Read mode", secure ? "Secure" : "Fast", width: 24),
            Self.field("Utilize accurate stream", "Yes", width: 24),
            Self.field("Defeat audio cache", yes(secure), width: 24),
            Self.field("Make use of C2 pointers", yes(tracks.contains { $0.c2Sectors != nil }), width: 24),
            "",
            Self.field("Read offset correction", String(drive.readOffset), width: 44),
            Self.field("Overread into Lead-In and Lead-Out", "No", width: 44),
            Self.field("Fill up missing offset samples with silence", "Yes", width: 44),
            Self.field("Delete leading and trailing silent blocks", "No", width: 44),
            Self.field("Null samples used in CRC calculations", "Yes", width: 44),
            Self.field("Used interface", "macOS IOKit (DKIOCCDREAD)", width: 44),
            Self.field("Gap handling", "Appended to previous track", width: 44),
        ]
    }

    private var eacOutputFormat: [String] {
        guard let encoding else {
            return [
                Self.field("Used output format", "WAV", width: 32),
                Self.field("Sample format", "44.100 Hz; 16 Bit; Stereo", width: 32),
            ]
        }
        let format = encoding.format
        let bits =
            (encoding.hdcdDecoded == true || encoding.dtsDecoded != nil) && format.isLossless ? format.wideBits : 16
        var lines = [
            Self.field("Used output format", format.name, width: 32),
            Self.field("Encoder", encoding.encoder, width: 32),
        ]
        if let settings = encoding.settingsText { lines.append(Self.field("Encoder settings", settings, width: 32)) }
        lines.append(
            Self.field("Sample format", "44.100 Hz; \(bits) Bit; \(encoding.dtsDecoded ?? "Stereo")", width: 32))
        return lines
    }

    /// The TOC table: each track's start and length (M:SS.FF) and its first and last sector.
    static func eacTOC(_ toc: TOC) -> [String] {
        var lines = [
            "TOC of the extracted CD",
            "",
            "     Track |   Start  |  Length  | Start sector | End sector ",
            "    ---------------------------------------------------------",
        ]
        for (index, track) in toc.tracks.enumerated() {
            let end =
                track.kind == .audio
                ? toc.sectorRange(of: track).upperBound
                : index + 1 < toc.tracks.count ? toc.tracks[index + 1].startLBA : toc.leadOutLBA
            lines.append(
                String(format: "%9d  |", track.number) + tocTime(track.startLBA).leftPadded(9) + " |"
                    + tocTime(end - track.startLBA).leftPadded(9) + " |" + String(format: "%10d    |", track.startLBA)
                    + String(format: "%9d   ", end - 1))
        }
        return lines
    }

    /// "3:20.37": minutes, seconds, and frames.
    static func tocTime(_ sectors: Int) -> String {
        String(format: "%d:%02d.%02d", sectors / 4500, sectors / 75 % 60, sectors % 75)
    }

    /// "0:00:02.33": hours, minutes, seconds, and frames.
    static func gapTime(_ sectors: Int) -> String {
        String(format: "%d:%02d:%02d.%02d", sectors / 270_000, sectors / 4500 % 60, sectors / 75 % 60, sectors % 75)
    }

    /// "0:01:05": a position in a track, to the second.
    static func positionTime(_ seconds: Int) -> String {
        String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    /// The suspicious positions of sectors that no reads agreed on: a second, or a run of
    /// seconds ("0:01:05 - 0:01:07").
    static func suspiciousPositions(_ sectors: [Int]) -> [String] {
        var runs = [ClosedRange<Int>]()
        for second in Set(sectors.map { $0 / 75 }).sorted() {
            if let last = runs.last, second == last.upperBound + 1 {
                runs[runs.count - 1] = last.lowerBound...second
            } else {
                runs.append(second...second)
            }
        }
        return runs.map {
            "Suspicious position " + positionTime($0.lowerBound)
                + ($0.count > 1 ? " - " + positionTime($0.upperBound) : "")
        }
    }

    /// True if AccurateRip or CTDB proves the track.
    private func eacVerified(_ track: Track) -> Bool {
        ctdb.status == .verified || ctdb.status == .repaired || track.accurateRip == .accurate
            || track.accurateRip == .otherPressings || (track.ctdbConfidence ?? 0) > 0
    }

    private func eacTrack(_ track: Track, toc: TOC?, folder: URL) -> [String] {
        let indent = "     "
        var lines = [String(format: "Track %2d", track.number), ""]
        if encoding?.silentTracksLeftOut?.contains(track.number) == true {
            lines.append(indent + "Filename (none: digital silence, left out of the album)")
        } else if let encoding, let file = encoding.file(ofTrack: track.number) {
            lines.append(indent + "Filename " + URL(filePath: encoding.folder).appending(path: file).path)
        } else {
            lines.append(indent + "Filename " + folder.appending(path: track.file).path)
        }
        lines.append("")
        // Track 1's pre-gap is the part of the disc before it, with the two seconds before LBA 0.
        let isFirst = toc?.audioTracks.first?.number == track.number
        let gap =
            isFirst && toc?.tracks.first?.kind == .audio
            ? CDDA.leadInSectors + track.startLBA : track.pregapUnknown == true ? 0 : track.pregapSectors ?? 0
        if gap > 0 { lines += [indent + "Pre-gap length  " + Self.gapTime(gap), ""] }
        let suspicious = Self.suspiciousPositions(track.unresolvedSectors)
        if !suspicious.isEmpty { lines += suspicious.map { indent + $0 } + [""] }
        if let peak = track.peak {
            let tenths = min(peak, 32767) * 1000 / 32767
            lines.append(indent + "Peak level \(tenths / 10).\(tenths % 10) %")
        }
        let readSeconds = track.readSeconds ?? track.seconds.map(Double.init)
        if let readSeconds, readSeconds > 0 {
            lines.append(
                indent + String(format: "Extraction speed %.1f X", Double(track.sectors) / 75 / readSeconds))
        }
        if secure, track.sectors > 0 {
            let tenths = (track.sectors - min(track.suspectSectors.count, track.sectors)) * 1000 / track.sectors
            lines.append(indent + "Track quality \(tenths / 10).\(tenths % 10) %")
        }
        if let test = track.testCRC32 { lines.append(indent + "Test CRC " + test) }
        if let copy = track.crc32 { lines.append(indent + "Copy CRC " + copy) }
        if track.repairedSamples > 0 {
            lines.append(indent + "Repaired \(track.repairedSamples) samples with CTDB's repair data")
        }
        lines.append(indent + eacAccurateRip(track))
        lines.append(indent + (track.unresolvedSectors.isEmpty || eacVerified(track) ? "Copy OK" : "Copy finished"))
        lines.append("")
        return lines
    }

    /// The AccurateRip line: "Accurately ripped (confidence 9)  [10F5E254]  (AR v2)". Of a
    /// track that does not match, EAC names the checksum with the most submissions.
    private func eacAccurateRip(_ track: Track) -> String {
        let checksums = track.accurateRipChecksums ?? []
        let v2 = checksums.count == 2 ? "  [\(checksums[1])]" : ""
        switch track.accurateRip {
        case .accurate:
            let confidence = track.accurateRipConfidence ?? []
            if confidence.count == 2, confidence[1] == 0, checksums.count == 2 {
                return "Accurately ripped (confidence \(confidence[0]))  [\(checksums[0])]  (AR v1)"
            }
            let count = confidence.count == 2 ? " (confidence \(confidence[1]))" : ""
            return "Accurately ripped\(count)\(v2)  (AR v2)"
        case .otherPressings:
            let offsets = track.matchingOffsets.map { $0 > 0 ? "+\($0)" : "\($0)" }.joined(separator: ", ")
            return "Accurately ripped as another pressing"
                + (offsets.isEmpty ? "" : " (offset \(offsets))") + "\(v2)  (AR v2)"
        case .notAccurate:
            guard let top = track.accurateRipTop else { return "Cannot be verified as accurate\(v2)  (AR v2)" }
            return "Cannot be verified as accurate (confidence \(top.confidence))"
                + (v2.isEmpty ? "" : "\(v2),") + " AccurateRip returned [\(top.checksum)]  (AR v2)"
        case .notInDatabase, .noChecksum:
            return "Track not present in AccurateRip database"
        }
    }

    private var eacSummary: [String] {
        let accurate = tracks.filter { $0.accurateRip == .accurate || $0.accurateRip == .otherPressings }.count
        let notAccurate = tracks.filter { $0.accurateRip == .notAccurate }.count
        let absent = tracks.filter { $0.accurateRip == .notInDatabase || $0.accurateRip == .noChecksum }.count
        var lines = [String]()
        if accurate == tracks.count {
            lines.append("All tracks accurately ripped")
        } else if absent == tracks.count {
            lines.append("None of the tracks are present in the AccurateRip database")
        } else if accurate == 0, absent == 0 {
            lines += [
                "No tracks could be verified as accurate",
                "You may have a different pressing from the one(s) in the database",
            ]
        } else {
            if accurate > 0 { lines.append(String(format: "%2d track(s) accurately ripped", accurate)) }
            if notAccurate > 0 {
                lines.append(String(format: "%2d track(s) could not be verified as accurate", notAccurate))
            }
            if absent > 0 {
                lines.append(String(format: "%2d track(s) not present in the AccurateRip database", absent))
            }
            lines += ["", "Some tracks could not be verified as accurate"]
        }
        lines.append("")
        let withErrors = tracks.filter { !$0.unresolvedSectors.isEmpty }
        if withErrors.isEmpty {
            lines.append("No errors occurred")
        } else if withErrors.allSatisfy({ $0.repairedSamples > 0 && eacVerified($0) }) {
            lines.append("There were errors, corrected with CTDB's repair data")
        } else if withErrors.allSatisfy(eacVerified) {
            lines.append("There were errors, but the tracks with them are verified")
        } else {
            lines.append("There were errors")
        }
        return lines
    }

    /// The section that EAC's CUETools DB plugin writes: the disc, and each track's submissions.
    private func eacCTDB(toc: TOC?) -> [String] {
        var lines = ["---- CUETools DB", ""]
        let id = toc.map { "[CTDB TOCID: \($0.ctdbTOCID)] " } ?? ""
        switch ctdb.status {
        case .notInDatabase:
            lines.append(id + "disk not present in database")
            return lines
        case .notChecked:
            lines.append(id + "not checked")
            return lines
        case .verified, .repaired, .partlyRepaired, .notVerified:
            let shift = ctdb.shift.map { $0 == 0 ? "" : ", at an offset of \($0 > 0 ? "+" : "")\($0) samples" } ?? ""
            lines.append(id + "found" + shift)
        }
        lines.append("Track | CTDB Status")
        for track in tracks where track.number > 0 {
            let confidence = track.ctdbConfidence ?? 0
            let count = ctdb.submissions.map { "(\(confidence)/\($0))" } ?? "(\(confidence))"
            var status = confidence > 0 ? "\(count) Accurately ripped" : "\(count) No entry matches"
            if track.repairedSamples > 0 { status += ", after the repair of \(track.repairedSamples) samples" }
            lines.append(String(format: "%3d   | ", track.number) + status)
        }
        return lines
    }

    /// What EAC's layout has no place for: Silverside's own findings, in plain sentences.
    private var eacNotes: [String] {
        var notes = [String]()
        if secure {
            notes.append(
                "Track quality is the share of the track's sectors that read the same the first time, with no re-read.")
        }
        if let preEmphasisText { notes.append(preEmphasisText) }
        if let deEmphasized = encoding?.deEmphasizedTracks, !deEmphasized.isEmpty {
            notes.append(
                (deEmphasized.count == 1 ? "Track " : "Tracks ") + Self.list(deEmphasized)
                    + " de-emphasized in the encoded files.")
        }
        if let hdcdText { notes.append(hdcdText) }
        if let dtsText { notes.append(dtsText) }
        if let silent = encoding?.silentTracksLeftOut, !silent.isEmpty {
            notes.append(
                (silent.count == 1 ? "Track " : "Tracks ") + Self.list(silent)
                    + (silent.count == 1 ? " is" : " are") + " digital silence, left out of the album.")
        }
        if let hiddenTrack {
            notes.append(
                "Hidden track before track 1: \(hiddenTrack.sectors) sectors in \(hiddenTrack.file), "
                    + (hiddenTrack.readsAgree ? "two reads agree." : "not verified: no two reads agree."))
        }
        for track in dataTracks ?? [] {
            notes.append(
                "Data track \(track.number): saved as \(track.file), \(track.sectors) sectors, CRC32 \(track.crc32).")
        }
        for failure in dataTrackFailures ?? [] {
            notes.append("Data track \(failure.number): not saved. \(failure.reason)")
        }
        if let image = encoding?.image { notes.append("Disc image: \(image)") }
        if let accepted, !isVerified {
            notes.append(
                "Accepted as it is on \(Self.eacDate(accepted)), and encoded, though not every track is verified.")
        }
        notes.append(
            "This log has the layout of EAC's logs, for the people and programs that read them. Silverside wrote it;"
                + " it has no EAC log checksum.")
        return ["---- Silverside", ""] + notes
    }

    /// The Markdown report at `markdown`, and the EAC-style log beside it ("Rip Report.log")
    /// when `eacLog` is true or a log is already there, so that a log, once written, follows
    /// every change of the report.
    public func writeReadable(to markdown: URL, eacLog: Bool = false) throws {
        try Data(self.markdown.utf8).write(to: markdown, options: .atomic)
        let log = Self.eacLogFile(besides: markdown)
        if eacLog || FileManager.default.fileExists(atPath: log.path) {
            try Data(eacStyleLog(folder: markdown.deletingLastPathComponent()).utf8).write(to: log, options: .atomic)
        }
    }

    /// The log beside a Markdown report: "Rip Report (Disc 2).log" for "Rip Report (Disc 2).md".
    public static func eacLogFile(besides markdown: URL) -> URL {
        markdown.deletingPathExtension().appendingPathExtension("log")
    }
}

extension String {
    fileprivate func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
