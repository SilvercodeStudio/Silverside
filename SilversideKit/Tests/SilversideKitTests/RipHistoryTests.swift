import Foundation
import Testing

@testable import SilversideKit

/// The history's own log: rips stay in it after their files move, and can be found again.
struct RipHistoryTests {
    @Test func keepsARipAndFindsItAgainAfterAMove() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (folder, library) = try PreEmphasisTests().makeRip(emphasized: [])
        let files = try DiscEncoder(format: .flac).encode(try RippedDisc(folder: folder), into: library)
        let album = files[0].deletingLastPathComponent()
        let history = RipHistory(directory: root.appending(path: "History"))

        history.recordReport(at: folder.appending(path: "disc.json"))
        history.recordAlbum(in: album)
        let entries = history.entries()
        // The rip and its album report are the same rip.
        #expect(entries.count == 1)
        let (key, entry) = try #require(entries.first)
        #expect(entry.report.tracks.count == 3)
        // Recording again changes nothing, unless the report or its place does.
        let before = try Data(contentsOf: history.directory.appending(path: key + ".json"))
        history.recordAlbum(in: album)
        #expect(try Data(contentsOf: history.directory.appending(path: key + ".json")) == before)

        // The album moves to a NAS: the history still has it, and finds it there.
        let nas = root.appending(path: "NAS/Music")
        try FileManager.default.createDirectory(at: nas, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: album, to: nas.appending(path: album.lastPathComponent))
        try FileManager.default.removeItem(at: folder)
        #expect(!FileManager.default.fileExists(atPath: history.entries()[key]!.file))
        #expect(history.locate([key], in: root.appending(path: "NAS")) == 1)
        let moved = try #require(history.entries()[key])
        #expect(moved.file.hasPrefix(nas.path) && FileManager.default.fileExists(atPath: moved.file))
        #expect(!moved.hasAudio)

        try history.forget(key: key)
        #expect(history.entries().isEmpty)
    }

    /// A repair's "… repaired" folder keeps the rip's time, but is a rip of its own.
    @Test func tellsARepairedFolderFromItsRip() throws {
        let toc = try TOC(audioTrackStarts: [0], leadOutLBA: 100)
        let report = RipReport(
            drive: .init(vendor: "V", product: "P", revision: "1", readOffset: 0, offsetSource: "test"), secure: true,
            toc: toc, tracks: [], ctdb: .init(status: .verified))
        let rip = URL(filePath: "/rips/Album/disc.json")
        let repaired = URL(filePath: "/rips/Album repaired/disc.json")
        #expect(RipHistory.key(of: report, file: rip) != RipHistory.key(of: report, file: repaired))
        #expect(
            RipHistory.key(of: report, file: rip)
                == RipHistory.key(of: report, file: URL(filePath: "/NAS/Album/Rip Report.json")))
    }
}
