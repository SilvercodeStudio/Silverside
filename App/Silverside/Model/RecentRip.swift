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
    /// True when the folder has the rip's audio, so the rip can be pooled or repaired.
    var hasAudio: Bool
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

    /// The album, with the disc's number in a set: "Europe '72 (Disc 2)".
    var title: String {
        guard let release = report.release else { return folder.lastPathComponent }
        guard release.media.count > 1, let position = report.discPosition else { return release.title }
        return "\(release.title) (Disc \(position))"
    }
    var artist: String { report.release?.artist ?? "" }
    var isVerified: Bool { report.isVerified }
    /// Where the rip is: its folder with the audio, or the library with its encoded files.
    var location: String { hasAudio ? "Rips folder" : "Library" }
    var driveName: String { "\(report.drive.vendor) \(report.drive.product)" }
    var date: Date { report.date }

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
        if unverified > 0 { parts.append("\(unverified) unverified") }
        if !hasAudio { parts.append("encoded") }
        return parts.joined(separator: " · ")
    }

    var details: String {
        "Ripped \(report.date.formatted(date: .abbreviated, time: .shortened)) on \(report.drive.vendor) \(report.drive.product), read offset \(report.drive.readOffset.signedDescription)."
            + (hasAudio ? "" : " Encoded into the library; the rip's WAV files were deleted, and this is its report.")
    }

    /// The rips in the rips folder, and the reports in the library's album folders, the
    /// newest first. A rip that is in both places (kept after encoding) is listed once.
    static func scan(rips: URL, library: URL) -> [RecentRip] {
        var found = scanRips(rips)
        var seen = Set(found.map { "\($0.report.toc) \($0.report.date.timeIntervalSince1970)" })
        for rip in scanLibrary(library, skipping: rips) {
            let key = "\(rip.report.toc) \(rip.report.date.timeIntervalSince1970)"
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
