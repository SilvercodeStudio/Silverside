import Foundation

/// Move to Trash for an earlier rip: the files that are the rip's own. A rip in the rips
/// folder is its folder, with the WAV files; its encoded files in the library stay, with the
/// library's copy of its report. A rip kept in the library is its report (JSON and Markdown),
/// its encoded files, its data tracks, its disc image, and the CUE sheets that name only its
/// files, but not a file that another report in the same album folder lists: two rips of a
/// disc can be encoded into one folder. The album's cover stays, for the album's other files.
public enum RipRemoval {
    /// The files to move, those that exist, the reports last. `reportFile` is a rip's
    /// `disc.json`, or an album folder's `Rip Report*.json`.
    public static func files(ofReportAt reportFile: URL, hasAudio: Bool) -> [URL] {
        let folder = reportFile.deletingLastPathComponent()
        if hasAudio { return [folder] }
        var files = [URL]()
        if let encoding = (try? RipReport.read(from: reportFile))?.encoding {
            let others = otherReportsFiles(in: folder, besides: reportFile)
            files += ownFiles(of: encoding, in: folder).filter { !others.contains($0.standardizedFileURL.path) }
            let shared = Set(others.map { URL(filePath: $0).lastPathComponent })
            files += CueSheet.sheets(in: folder, namingOnly: Set(encoding.files.map(\.file))).filter {
                !CueSheet.sheet($0, namesOnly: shared)
            }
        }
        // The reports last: if a move fails, the report is still there to try again with.
        files += [reportFile, reportFile.deletingPathExtension().appendingPathExtension("md")]
        return files.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Moves the rip's files to the Trash, where they can be put back. A rip folder is
    /// claimed first, so that a rip writing into it now keeps it (`RipFolder`).
    public static func moveToTrash(reportAt reportFile: URL, hasAudio: Bool) throws {
        let files = files(ofReportAt: reportFile, hasAudio: hasAudio)
        let folder = reportFile.deletingLastPathComponent()
        if hasAudio {
            let toc = try TOC(ctdbTOCString: RipReport.read(from: reportFile).toc)
            try RipFolder.claimExactly(folder, toc: toc)
        }
        defer { if hasAudio { RipFolder.release(folder) } }
        for file in files { try FileManager.default.trashItem(at: file, resultingItemURL: nil) }
    }

    /// An encoding's files in the album folder, and its disc image, which has a folder of its own.
    static func ownFiles(of encoding: RipReport.Encoding, in folder: URL) -> [URL] {
        var files = encoding.files.map { folder.appending(path: $0.file) }
        for image in encoding.dataTrackFiles ?? [] {
            // The image, and the folder of the files on it, which has its name.
            files += [folder.appending(path: image), folder.appending(path: (image as NSString).deletingPathExtension)]
        }
        if let image = encoding.image.map({ URL(filePath: $0) }) {
            files += [image, image.deletingPathExtension().appendingPathExtension("cue")]
        }
        return files
    }

    /// The paths of the files that the folder's other reports list.
    static func otherReportsFiles(in folder: URL, besides reportFile: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var listed = Set<String>()
        for name in names where name.hasPrefix("Rip Report") && name.hasSuffix(".json") {
            let file = folder.appending(path: name)
            guard name != reportFile.lastPathComponent, let encoding = (try? RipReport.read(from: file))?.encoding
            else { continue }
            listed.formUnion(ownFiles(of: encoding, in: folder).map(\.standardizedFileURL.path))
        }
        return listed
    }
}
