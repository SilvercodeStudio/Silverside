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

    /// An album report that has not changed since the history kept it is not read again, so a
    /// library on a NAS costs only its listings. A changed one, and a rip's disc.json, are.
    @Test func readsOnlyTheAlbumReportsThatChanged() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (folder, library) = try PreEmphasisTests().makeRip(emphasized: [])
        let files = try DiscEncoder(format: .flac).encode(try RippedDisc(folder: folder), into: library)
        let report = files[0].deletingLastPathComponent().appending(path: "Rip Report.json")
        var edits = MetadataEdits()
        edits.album = "Edited"
        try edits.save(inReportAt: report)
        let history = RipHistory(directory: root.appending(path: "History"))

        let read = try #require(history.entry(forReportAt: report, hasAudio: false))
        #expect(read.edits?.album == "Edited")
        #expect(read.stamp != nil)
        try history.record(read)

        // The history's copy says another drive, so a result with it was not read from the file.
        var kept = read
        kept.report.drive.vendor = "Kept"
        let known = [read.file: kept]
        #expect(history.entry(forReportAt: report, hasAudio: false, known: known)?.report.drive.vendor == "Kept")
        #expect(RipHistory.isThere(kept, key: kept.key))
        // A rip's disc.json is read each time: its album folder can follow the library setting.
        let disc = folder.appending(path: "disc.json")
        let rip = try #require(history.entry(forReportAt: disc, hasAudio: true))
        var keptRip = rip
        keptRip.report.drive.vendor = "Kept"
        #expect(history.entry(forReportAt: disc, hasAudio: true, known: [rip.file: keptRip])?.report == rip.report)

        // A changed report is read again. (A URL keeps the size and time it was given, as a
        // folder listing gives them, so a new listing has new URLs.)
        edits.album = "Edited Again"
        try edits.save(inReportAt: report)
        let listed = URL(filePath: report.path)
        let again = try #require(history.entry(forReportAt: listed, hasAudio: false, known: known))
        #expect(again.report.drive.vendor != "Kept")
        #expect(again.edits?.album == "Edited Again")

        // A rip that the scan did not find (a library folder used before) is checked the same way:
        // the kept entry while it has not changed, its new names after it did.
        var stale = again
        stale.edits = MetadataEdits(album: "Stale")
        #expect(history.current(stale, key: stale.key)?.edits?.album == "Stale")
        edits.album = "Edited Once More"
        try edits.save(inReportAt: report)
        #expect(history.current(stale, key: stale.key)?.edits?.album == "Edited Once More")
        #expect(history.current(stale, key: "another rip") == nil)
        try FileManager.default.removeItem(at: report)
        #expect(history.current(stale, key: stale.key) == nil)
    }

    /// A disc that MusicBrainz does not know gets the names of its newest rip that has any.
    @Test func findsTheNamesOfADiscThatMusicBrainzDoesNotKnow() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = RipHistory(directory: root.appending(path: "History"))
        let toc = try TOC(audioTrackStarts: [0, 300], leadOutLBA: 700)
        let other = try TOC(audioTrackStarts: [0, 400], leadOutLBA: 700)
        func rip(_ name: String, toc: TOC, daysAgo: Double, title: String?) throws -> URL {
            let folder = root.appending(path: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "disc.json")
            let date = Date(timeIntervalSince1970: (1_800_000_000 - daysAgo * 86_400).rounded())
            try RipSetTests.report(.manual(toc: toc), toc: toc, date: date).write(to: file)
            var edits = MetadataEdits()
            edits.setTitle(title, ofTrack: 1)
            if title != nil { try edits.save(inReportAt: file) }
            _ = try history.record(try RipReport.read(from: file), file: file, hasAudio: true)
            return file
        }
        #expect(history.newestNamedRip(of: toc) == nil)
        _ = try rip("Old", toc: toc, daysAgo: 3, title: "Old Name")
        let named = try rip("Named", toc: toc, daysAgo: 2, title: "New Name")
        _ = try rip("Unnamed", toc: toc, daysAgo: 1, title: nil)
        _ = try rip("Other", toc: other, daysAgo: 0, title: "Another Disc")
        // The newest rip has no names, so the one before it gives them.
        #expect(history.newestNamedRip(of: toc)?.standardizedFileURL == named.standardizedFileURL)
        // A rip whose files are gone does not count.
        try FileManager.default.removeItem(at: named.deletingLastPathComponent())
        #expect(history.newestNamedRip(of: toc)?.deletingLastPathComponent().lastPathComponent == "Old")
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
