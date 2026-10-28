import Foundation

/// Move to Trash for an earlier rip: the files that are the rip's own. A rip in the rips
/// folder is its folder, with the WAV files; its encoded files in the library stay, with the
/// library's copy of its report. A rip kept in the library is its report (JSON and Markdown)
/// and its encoded files, but not a file that another report in the same album folder lists:
/// two rips of a disc can be encoded into one folder. The album folder's cover and CUE sheet
/// stay, because the album's other files can need them.
public enum RipRemoval {
    /// The files to move, those that exist. `reportFile` is a rip's `disc.json`, or an album
    /// folder's `Rip Report*.json`.
    public static func files(ofReportAt reportFile: URL, hasAudio: Bool) -> [URL] {
        let folder = reportFile.deletingLastPathComponent()
        if hasAudio { return [folder] }
        let manager = FileManager.default
        var files = [reportFile, reportFile.deletingPathExtension().appendingPathExtension("md")]
        if let encoding = (try? RipReport.read(from: reportFile))?.encoding {
            let others = otherReportsFiles(in: folder, besides: reportFile)
            let own = encoding.files.map(\.file) + (encoding.dataTrackFiles ?? []) + [encoding.image].compactMap { $0 }
            files += own.filter { !others.contains($0) }.map { folder.appending(path: $0) }
        }
        return files.filter { manager.fileExists(atPath: $0.path) }
    }

    /// Moves the files to the Trash, where they can be put back.
    public static func moveToTrash(_ files: [URL]) throws {
        for file in files { try FileManager.default.trashItem(at: file, resultingItemURL: nil) }
    }

    /// The names of the files that the folder's other reports list.
    static func otherReportsFiles(in folder: URL, besides reportFile: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var listed = Set<String>()
        for name in names where name.hasPrefix("Rip Report") && name.hasSuffix(".json") {
            let file = folder.appending(path: name)
            guard file.lastPathComponent != reportFile.lastPathComponent,
                let encoding = (try? RipReport.read(from: file))?.encoding
            else { continue }
            listed.formUnion(encoding.files.map(\.file))
            listed.formUnion(encoding.dataTrackFiles ?? [])
            if let image = encoding.image { listed.insert(image) }
        }
        return listed
    }
}
