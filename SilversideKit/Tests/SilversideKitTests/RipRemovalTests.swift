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
        func write(_ name: String, files: [String]) throws -> URL {
            var report = RipReport(
                date: Date(), drive: drive, secure: true, toc: toc, tracks: [], ctdb: .init(status: .verified))
            report.encoding = .init(
                format: .flac, encoder: "t", folder: folder.path,
                files: files.enumerated().map { .init(track: $0.offset + 1, file: $0.element) })
            let url = folder.appending(path: name)
            try report.write(to: url)
            return url
        }
        let deluxe = try write("Rip Report (Disc 1).json", files: ["01-01 Box of Rain.flac", "shared.flac"])
        _ = try write("Rip Report.json", files: ["01 Box of Rain.flac", "shared.flac"])
        for name in [
            "01-01 Box of Rain.flac", "01 Box of Rain.flac", "shared.flac", "Rip Report (Disc 1).md", "cover.jpg",
        ] {
            try Data().write(to: folder.appending(path: name))
        }
        let files = RipRemoval.files(ofReportAt: deluxe, hasAudio: false).map(\.lastPathComponent)
        #expect(Set(files) == ["Rip Report (Disc 1).json", "Rip Report (Disc 1).md", "01-01 Box of Rain.flac"])
        // A rip with its WAV files is its folder.
        #expect(
            RipRemoval.files(ofReportAt: folder.appending(path: "disc.json"), hasAudio: true).map(\.path) == [
                folder.path
            ])
    }
}
