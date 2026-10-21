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

    var subtitle: String {
        let tracks = report.tracks.count
        if isVerified { return artist }
        let unverified = tracks - verifiedCount
        return artist.isEmpty ? "\(unverified) unverified" : "\(artist) · \(unverified) unverified"
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
