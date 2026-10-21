import CDRipKit
import Foundation

/// An earlier rip in the rips folder: its report, for the sidebar and the results view.
nonisolated struct RecentRip: Identifiable, Sendable {
    var folder: URL
    var report: RipReport
    var id: URL { folder }

    var title: String { report.release?.title ?? folder.lastPathComponent }
    var artist: String { report.release?.artist ?? "" }
    var isVerified: Bool { report.isVerified }

    /// The tracks that AccurateRip or CTDB proves.
    var verifiedCount: Int {
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
        return parts.joined(separator: " · ")
    }

    var details: String {
        "Ripped \(report.date.formatted(date: .abbreviated, time: .shortened)) on \(report.drive.vendor) \(report.drive.product), read offset \(report.drive.readOffset.signedDescription)."
    }

    /// The rips in a folder, the newest first.
    static func scan(_ folder: URL) -> [RecentRip] {
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
        return rips.sorted { $0.report.date > $1.report.date }
    }
}
