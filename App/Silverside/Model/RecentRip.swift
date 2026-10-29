import Foundation
import SilversideKit

/// An earlier rip, for the sidebar and the results view: a rip in the rips folder (its
/// WAV files and `disc.json`), or one that was encoded, whose report is kept in the
/// library's album folder as "Rip Report (Disc N).json" after the WAV files are deleted.
nonisolated struct RecentRip: Identifiable, Sendable {
    /// The rip's folder, or the album folder in the library.
    var folder: URL
    /// The report file: `disc.json` in a rip folder, or the album folder's copy.
    var file: URL
    var report: RipReport
    /// The album's names as edited: the rip's own edits, with those kept for its release on top.
    var names = MetadataEdits()
    /// True when the folder has the rip's audio, so the rip can be pooled or repaired.
    var hasAudio: Bool
    /// True when the rip is only in the history: its files were moved or deleted (`RipHistory`).
    /// `folder` and `file` are where they were last seen.
    var isMissing = false
    var id: URL { file }

    /// A rip in the rips folder.
    init(folder: URL, report: RipReport) {
        self.folder = folder
        file = folder.appending(path: "disc.json")
        self.report = report
        hasAudio = true
    }

    /// A report kept in the library, next to the encoded files.
    init(libraryReport file: URL, report: RipReport) {
        folder = file.deletingLastPathComponent()
        self.file = file
        self.report = report
        hasAudio = false
    }

    /// A rip from the history: where its report was last seen, there or not.
    init(history entry: RipHistory.Entry, isMissing: Bool) {
        file = entry.url
        folder = entry.url.deletingLastPathComponent()
        report = entry.report
        hasAudio = entry.hasAudio
        self.isMissing = isMissing
    }

    /// The rip's key in the history.
    var historyKey: String { RipHistory.key(of: report, file: file) }

    /// The album, with the disc's number in a set: "Europe '72 (Disc 2)".
    var title: String {
        guard let release = report.release else { return folder.lastPathComponent }
        let album = names.album ?? release.title
        guard release.media.count > 1, let position = report.discPosition else { return album }
        return "\(album) (Disc \(position))"
    }
    var artist: String { names.albumArtist ?? report.release?.artist ?? "" }
    var isVerified: Bool { report.isVerified }
    /// Where the rip is: its folder with the audio, or the library with its encoded files.
    var location: String { isMissing ? "Moved or deleted" : hasAudio ? "Rips folder" : "Library" }
    var driveName: String { "\(report.drive.vendor) \(report.drive.product)" }
    var date: Date { report.date }

    /// A rip that a database did not have, or that is not verified, with its audio to check
    /// again: its WAV files, or the album's lossless files, not an HDCD decode.
    var canCheckAgain: Bool {
        guard report.mayCheckAgain else { return false }
        return hasAudio
            || (report.encoding?.format.isLossless == true && report.encoding?.hdcdDecoded != true
                && report.encoding?.dtsDecoded == nil)
    }

    /// The tracks that AccurateRip or CTDB proves.
    var verifiedCount: Int { Self.verifiedCount(of: report) }

    static func verifiedCount(of report: RipReport) -> Int {
        let wholeDisc = report.ctdb.status == .verified || report.ctdb.status == .repaired
        return report.tracks.filter {
            wholeDisc || $0.accurateRip == .accurate || $0.accurateRip == .otherPressings
                || ($0.ctdbConfidence ?? 0) > 0
        }.count
    }

    /// The artist, when the rip was made (two rips of a disc look alike otherwise), and what
    /// is not verified. The drive is in `details`, for a tooltip: its names wrap badly.
    var subtitle: String {
        var parts = [String]()
        if !artist.isEmpty { parts.append(artist) }
        parts.append(report.date.formatted(date: .abbreviated, time: .omitted))
        let unverified = report.tracks.count - verifiedCount
        if unverified > 0 { parts.append("\(unverified) unverified" + (report.accepted != nil ? ", accepted" : "")) }
        if isMissing { parts.append("moved or deleted") } else if !hasAudio { parts.append("encoded") }
        return parts.joined(separator: " · ")
    }

    var details: String {
        "Ripped \(report.date.formatted(date: .abbreviated, time: .shortened)) on \(report.drive.vendor) \(report.drive.product), read offset \(report.drive.readOffset.signedDescription)."
            + (hasAudio ? "" : " Encoded into the library; the rip's WAV files were deleted, and this is its report.")
    }

    /// The rips in the rips folder, and the reports in the library's album folders, the
    /// newest first. A rip that is in both places (kept after encoding) is listed once.
    /// The rips found, kept in the history (`RipHistory`), and the history's other rips: those
    /// elsewhere (a library folder used before), and those whose files are gone, as missing.
    static func scan(rips: URL, library: URL, history: RipHistory) -> (present: [RecentRip], missing: [RecentRip]) {
        var present = scan(rips: rips, library: library)
        var keys = Set<String>()
        for rip in present {
            keys.insert((try? history.record(rip.report, file: rip.file, hasAudio: rip.hasAudio)) ?? rip.historyKey)
        }
        var missing = [RecentRip]()
        for (key, entry) in history.entries() where !keys.contains(key) {
            // There only if the report at that place is still this rip's: a later rip of the disc
            // can have taken its folder.
            let isThere = RipHistory.isThere(entry, key: key)
            if isThere {
                present.append(RecentRip(history: entry, isMissing: false))
            } else {
                missing.append(RecentRip(history: entry, isMissing: true))
            }
        }
        return (
            named(present).sorted { $0.report.date > $1.report.date },
            named(missing).sorted { $0.report.date > $1.report.date }
        )
    }

    /// The rips with their album's names as edited, as the library has them.
    private static func named(_ rips: [RecentRip]) -> [RecentRip] {
        let store = ReleaseEditsStore()
        return rips.map { rip in
            guard let release = rip.report.release else { return rip }
            var named = rip
            named.names = MetadataEdits.current(forReportAt: rip.file, release: release, store: store).albumLevel
            return named
        }
    }

    static func scan(rips: URL, library: URL) -> [RecentRip] {
        var found = scanRips(rips)
        // A repair's report keeps the rip's time; its own time tells it apart.
        func identity(_ rip: RecentRip) -> String {
            "\(rip.report.toc) \(rip.report.date.timeIntervalSince1970) \(rip.report.repaired?.timeIntervalSince1970 ?? 0)"
        }
        var seen = Set(found.map(identity))
        for rip in scanLibrary(library, skipping: rips) {
            let key = identity(rip)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            found.append(rip)
        }
        return found.sorted { $0.report.date > $1.report.date }
    }

    private static func scanRips(_ folder: URL) -> [RecentRip] {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        else { return [] }
        var rips = [RecentRip]()
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let json = entry.appending(path: "disc.json")
            guard manager.fileExists(atPath: json.path), let report = try? RipReport.read(from: json) else { continue }
            rips.append(RecentRip(folder: entry, report: report))
        }
        return rips
    }

    /// "Rip Report*.json" files up to four levels down (the album folder template is
    /// usually artist/album), leaving the rips folder alone if it is inside the library.
    private static func scanLibrary(_ library: URL, skipping rips: URL) -> [RecentRip] {
        let manager = FileManager.default
        guard
            let enumerator = manager.enumerator(
                at: library, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        let skipped = rips.standardizedFileURL.path
        var found = [RecentRip]()
        while let entry = enumerator.nextObject() as? URL {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                if enumerator.level >= 4 || entry.standardizedFileURL.path == skipped { enumerator.skipDescendants() }
                continue
            }
            let name = entry.lastPathComponent
            // A decoded copy beside an album ("… (HDCD)") is not a rip of its own.
            guard name.hasPrefix("Rip Report"), name.hasSuffix(".json"), let report = try? RipReport.read(from: entry),
                report.encoding?.albumSuffix == nil
            else { continue }
            found.append(RecentRip(libraryReport: entry, report: report))
        }
        return found
    }
}
