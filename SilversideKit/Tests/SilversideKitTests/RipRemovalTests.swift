import Foundation
import Testing

@testable import SilversideKit

struct RipRemovalTests {
    /// *American Beauty*: a rip as disc 1 of the deluxe edition and a rip of the single-disc
    /// edition, encoded into one album folder. Each rip's own files go; the shared ones stay.
    @Test func leavesTheFilesOfAnotherRipInTheFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "RipRemoval-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let toc = try TOC(audioTrackStarts: [0, 1000], leadOutLBA: 2000)
        let drive = RipReport.Drive(
            vendor: "SIM", product: "DRIVE", revision: "1.0", readOffset: 6, offsetSource: "--offset")
        func write(_ name: String, files: [String], image: String? = nil) throws -> URL {
            var report = RipReport(
                date: Date(), drive: drive, secure: true, toc: toc, tracks: [], ctdb: .init(status: .verified))
            report.encoding = .init(
                format: .flac, encoder: "t", folder: folder.path,
                files: files.enumerated().map { .init(track: $0.offset + 1, file: $0.element) })
            report.encoding?.image = image
            let url = folder.appending(path: name)
            try report.write(to: url)
            return url
        }
        let deluxe = try write(
            "Rip Report (Disc 1).json", files: ["01-01 Box of Rain.flac", "shared.flac"],
            image: folder.appending(path: "Images/American Beauty (Disc 1).flac").path)
        _ = try write("Rip Report.json", files: ["01 Box of Rain.flac", "shared.flac"])
        for name in [
            "01-01 Box of Rain.flac", "01 Box of Rain.flac", "shared.flac", "Rip Report (Disc 1).md", "cover.jpg",
        ] {
            try Data().write(to: folder.appending(path: name))
        }
        // The disc image is in a folder of its own, by its whole path, with its CUE sheet.
        try FileManager.default.createDirectory(
            at: folder.appending(path: "Images"), withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "Images/American Beauty (Disc 1).flac"))
        try Data().write(to: folder.appending(path: "Images/American Beauty (Disc 1).cue"))
        // The deluxe rip's CUE sheet names its files only; the other's names a shared one.
        try Data("FILE \"01-01 Box of Rain.flac\" WAVE\n".utf8).write(
            to: folder.appending(path: "American Beauty (Disc 1).cue"))
        try Data("FILE \"01 Box of Rain.flac\" WAVE\nFILE \"shared.flac\" WAVE\n".utf8).write(
            to: folder.appending(path: "American Beauty.cue"))
        let files = RipRemoval.files(ofReportAt: deluxe, hasAudio: false).map(\.lastPathComponent)
        #expect(
            files == [
                "01-01 Box of Rain.flac", "American Beauty (Disc 1).flac", "American Beauty (Disc 1).cue",
                "American Beauty (Disc 1).cue", "Rip Report (Disc 1).json", "Rip Report (Disc 1).md",
            ])
        // A rip folder that a rip has now stays where it is.
        let ripFolder = folder.appending(path: "rip")
        try FileManager.default.createDirectory(at: ripFolder, withIntermediateDirectories: true)
        let report = RipReport(
            date: Date(), drive: drive, secure: true, toc: toc, tracks: [], ctdb: .init(status: .verified))
        try report.write(to: ripFolder.appending(path: "disc.json"))
        try RipFolder.claimExactly(ripFolder, toc: toc)
        #expect(throws: RipFolderError.self) {
            try RipRemoval.moveToTrash(reportAt: ripFolder.appending(path: "disc.json"), hasAudio: true)
        }
        RipFolder.release(ripFolder)
        #expect(FileManager.default.fileExists(atPath: ripFolder.path))
        // A rip with its WAV files is its folder.
        #expect(
            RipRemoval.files(ofReportAt: folder.appending(path: "disc.json"), hasAudio: true).map(\.path) == [
                folder.path
            ])
    }
}
