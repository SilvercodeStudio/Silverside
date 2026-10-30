import Foundation

public enum RipCheckError: Error, Equatable, CustomStringConvertible {
    /// The rip's WAV files are gone, and the album's files are lossy or an HDCD decode.
    case noRippedAudio(URL)
    case noReport(URL)

    public var description: String {
        switch self {
        case .noRippedAudio(let folder):
            "\(folder.path) no longer has the ripped audio (its WAV files, or lossless files of the rip) to check."
        case .noReport(let file): "\(file.path) has no rip report."
        }
    }
}

/// Check Again: looks an earlier rip up in AccurateRip and CTDB again, as for a new disc, and
/// checks the rip's audio against what they have now. A new release is often in neither at
/// first, and they fill in over weeks. The audio is the rip's WAV files, or the album's
/// lossless files, each checked against the rip's CRC-32; the disc is not needed.
///
/// A result only gets better: a track that matched before keeps its match if the new lookup
/// finds less. The report (disc.json, or the album's "Rip Report (Disc N).json") gets the new
/// results and `checkedAgain`, and its Markdown is written again. A rip that CTDB now has but
/// does not verify can then be repaired (`RipRepair`).
public struct RipCheck {
    public struct Result: Sendable {
        public var before: RipReport
        public var after: RipReport

        /// True if any track's AccurateRip result or CTDB confidence, or the CTDB result, changed.
        public var changed: Bool {
            before.ctdb != after.ctdb
                || zip(before.tracks, after.tracks).contains {
                    $0.accurateRip != $1.accurateRip || $0.accurateRipConfidence != $1.accurateRipConfidence
                        || $0.ctdbConfidence != $1.ctdbConfidence
                }
        }

        /// The outcome in a sentence, for people.
        public var summary: String {
            var accurateRip: String
            let accurate = after.tracks.filter { $0.accurateRip == .accurate || $0.accurateRip == .otherPressings }
            if after.tracks.allSatisfy({ $0.accurateRip == .notInDatabase }) {
                accurateRip = "AccurateRip does not have this disc yet"
            } else {
                accurateRip = "AccurateRip: \(accurate.count) of \(after.tracks.count) tracks accurate"
                let silent = after.tracks.filter { $0.accurateRip == .noChecksum }.count
                if silent > 0 { accurateRip += " (\(silent) with no checksum)" }
            }
            let ctdb: String =
                switch after.ctdb.status {
                case .notInDatabase: "CTDB does not have it yet"
                case .notChecked: "CTDB not checked"
                default: "CTDB: \(after.ctdbSummary)"
                }
            let verdict =
                after.isVerified
                ? (before.isVerified ? "Verified." : "Now verified.")
                : (changed ? "Changed, but not verified." : "No change.")
            return "\(verdict) \(accurateRip); \(ctdb)."
        }
    }

    /// The rip's report: a rip folder's disc.json, or an album folder's report.
    public let reportFile: URL
    /// The client for the lookups. Tests give one with a fake transport.
    public var webClient = WebClient.shared
    public var editsStore = ReleaseEditsStore()
    /// Stops the check when set, from any thread.
    public var stop = StopToken()
    /// Lines for a log, for people.
    public var log: @Sendable (String) -> Void = { _ in }

    public init(reportAt file: URL) {
        reportFile = file
    }

    public func run() async throws -> Result {
        let disc: RippedDisc
        do {
            disc =
                reportFile.lastPathComponent == "disc.json"
                ? try RippedDisc(folder: reportFile.deletingLastPathComponent())
                : try RippedDisc(albumReportAt: reportFile, editsStore: editsStore)
        } catch EncodingError.lossySource(let folder), EncodingError.alreadyDecoded(let folder) {
            throw RipCheckError.noRippedAudio(folder)
        }
        guard let before = disc.report else { throw RipCheckError.noReport(reportFile) }
        let toc = disc.toc
        let audioTracks = toc.audioTracks
        let tracks = before.tracks.compactMap { reported in disc.tracks.first { $0.number == reported.number } }
        // A silent track left out of an album has no file: its audio is zeros.
        guard tracks.count == before.tracks.count,
            tracks.allSatisfy({ $0.isLeftOutSilence || FileManager.default.fileExists(atPath: $0.file.path) })
        else { throw RipCheckError.noRippedAudio(disc.folder) }

        // A new request each, not the cache's answer from the rip.
        let records = try await AccurateRipRecord.download(
            for: toc.accurateRipDiscID, client: webClient, useCache: false)
        let entries = try await CTDBEntry.lookup(toc, client: webClient, useCache: false)
            .sorted { $0.confidence > $1.confidence }
        log(
            records.isEmpty
                ? "AccurateRip does not have the disc."
                : "AccurateRip: \(records.count) pressings, up to "
                    + "\(records.flatMap { $0.tracks.map(\.confidence) }.max() ?? 0) submissions for a track.")
        log(
            entries.isEmpty
                ? "CTDB does not have the disc."
                : "CTDB: \(entries.count) entries, up to \(entries[0].confidence) submissions.")
        try stop.check()

        let stop = self.stop
        let samples = try await blocking {
            try tracks.map { track in
                try stop.check()
                return try disc.audio(of: track)
            }
        }
        // AccurateRip's other pressings and CTDB need the whole disc.
        let wholeDisc = before.tracks.map(\.number) == audioTracks.map(\.number)

        var after = before
        var starts = [Int]()
        var discAudio = [UInt32]()
        if wholeDisc {
            for track in samples {
                starts.append(discAudio.count)
                discAudio += track
            }
        }
        for (position, reported) in before.tracks.enumerated() {
            guard let index = audioTracks.firstIndex(where: { $0.number == reported.number }) else { continue }
            let known = records.entries(forTrackAt: index)
            var checked = reported
            checked.accurateRipConfidence = nil
            checked.matchingOffsets = []
            checked.accurateRip = .unmatched(trackAt: index, records: records)
            checked.accurateRipTop = .top(trackAt: index, records: records)
            if case .accurate(let v1, let v2) = RipPool.verification(
                of: samples[position], track: audioTracks[index], toc: toc, records: records)
            {
                checked.accurateRip = .accurate
                checked.accurateRipConfidence = [v1, v2]
                checked.matchingOffsets = [before.drive.readOffset]
            } else if wholeDisc,
                let shift = DiscRepairer.otherPressingShift(
                    of: discAudio, start: starts[position], length: samples[position].count,
                    edges: (index == 0, index == audioTracks.count - 1), known: known)
            {
                checked.accurateRip = .otherPressings
                checked.matchingOffsets = [before.drive.readOffset + shift]
            }
            let wasRight = reported.accurateRip == .accurate || reported.accurateRip == .otherPressings
            let isRight = checked.accurateRip == .accurate || checked.accurateRip == .otherPressings
            if isRight || !wasRight { after.tracks[position] = checked }
        }

        // A rip that CTDB verified or repaired stays so: its entry does not go away.
        if wholeDisc, before.ctdb.status != .verified, before.ctdb.status != .repaired {
            if entries.isEmpty {
                after.ctdb = RipReport.CTDBResult(status: .notInDatabase)
            } else {
                var repairer = DiscRepairer(toc: toc, records: records, entries: entries, reader: nil)
                repairer.stop = stop
                repairer.log = log
                let result = try await repairer.repair(samples.map { TrackAudio(samples: $0) }, repairing: false)
                after.ctdb = RipReport.CTDBResult(result)
                for position in after.tracks.indices where position < result.trackConfidences.count {
                    after.tracks[position].ctdbConfidence = result.trackConfidences[position]
                }
            }
        }
        after.checkedAgain = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

        try save(after, in: reportFile)
        // A rip folder's album copy gets the results too.
        if reportFile.lastPathComponent == "disc.json", let encoding = after.encoding {
            let discPart =
                (after.release?.media.count ?? 1) > 1 ? after.discPosition.map { " (Disc \($0))" } ?? "" : ""
            let albumReport = URL(filePath: encoding.folder, directoryHint: .isDirectory)
                .appending(path: "Rip Report\(discPart).json")
            if FileManager.default.fileExists(atPath: albumReport.path) { try save(after, in: albumReport) }
        }
        return Result(before: before, after: after)
    }

    /// Sets the results in a report file, and keeps every other key (the edits, the encoding);
    /// then writes its Markdown again.
    private func save(_ report: RipReport, in file: URL) throws {
        var object = (try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]) ?? [:]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try JSONSerialization.jsonObject(with: encoder.encode(report)) as? [String: Any] else {
            return
        }
        var target = (object["ripReport"] as? [String: Any]) ?? object
        for key in ["tracks", "ctdb", "checkedAgain"] { target[key] = encoded[key] }
        if object["ripReport"] != nil { object["ripReport"] = target } else { object = target }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)

        var shown = report
        if let release = report.release, let toc = try? TOC(ctdbTOCString: report.toc) {
            shown.release = MetadataEdits.current(forReportAt: file, release: release, store: editsStore)
                .applied(to: release, toc: toc)
        }
        let markdown =
            file.lastPathComponent == "disc.json"
            ? file.deletingLastPathComponent().appending(path: "Rip Report.md")
            : file.deletingPathExtension().appendingPathExtension("md")
        // An archive's folder has none, and gets none.
        if FileManager.default.fileExists(atPath: markdown.path) { try shown.writeReadable(to: markdown) }
    }
}
