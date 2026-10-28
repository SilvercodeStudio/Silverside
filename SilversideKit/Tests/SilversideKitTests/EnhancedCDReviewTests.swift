import Foundation
import Testing

@testable import SilversideKit

/// From the review of 2026-10-27 (fe07adb): repairs of Enhanced CDs, the data track images when
/// encoding, and the identity of a repair in the history.
struct EnhancedCDReviewTests {
    /// A rip that read the last track into the lead-out keeps those samples when a repair reads
    /// the track again with a reader that cannot reach there: its silence is no read, so it does
    /// not outvote the rip. With the probe, the re-reads reach the lead-out too.
    @Test(arguments: [false, true])
    func repairPreservesRecoveredLeadOut(probesLeadOut: Bool) async throws {
        let (toc, samples) = try EnhancedCDTests.disc()
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "rip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var tracks = [RipReport.Track]()
        for track in toc.audioTracks {
            let range = toc.sectorRange(of: track)
            var audio = Array(samples[(range.lowerBound * 588)..<(range.upperBound * 588)])
            if track.number == 2 { audio[100 * 588] ^= 123 }
            let name = String(format: "Track %02d.wav", track.number)
            try WAVFile.write(audio, to: folder.appending(path: name))
            tracks.append(
                .init(
                    number: track.number, file: name, startLBA: track.startLBA,
                    sectors: range.count, preEmphasis: false, accurateRip: .notInDatabase))
        }
        let report = RipReport(
            drive: .init(
                vendor: "SIM", product: "DRIVE", revision: "1", readOffset: 6,
                offsetSource: "test"), secure: true, toc: toc, tracks: tracks,
            ctdb: .init(status: .notChecked))
        try report.write(to: folder.appending(path: "disc.json"))
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 6)
        drive.readsSessionLeadOut = true
        var reader = AudioReader(drive: drive, toc: toc, readOffset: 6, canOverread: false)
        if probesLeadOut { reader.readableLeadOut = AudioReader.sessionLeadOut(of: toc, drive: drive) }
        var repair = RipRepair(toc: toc, folders: [folder])
        repair.reader = reader
        repair.cacheFlushSectors = 10
        repair.webClient = await DiscRipTests.web(toc: toc, samples: samples).client(in: root.appending(path: "cache"))
        let result = try await repair.run()
        if case .verified = result.outcome {} else { Issue.record("Expected CTDB verification") }
        let expected = Array(samples[(800 * 588)..<(1700 * 588)])
        let written = try WAVFile.read(repair.output.appending(path: "Track 02.wav"))
        #expect(written.dropLast(6) == expected.dropLast(6))
        #expect(Array(written.suffix(6)) == Array(expected.suffix(6)))
    }

    func dataRip() throws -> (RippedDisc, URL) {
        let (folder, library) = try PreEmphasisTests().makeRip(emphasized: [])
        var report = try RipReport.read(from: folder.appending(path: "disc.json"))
        let image = ISO9660Tests.image(start: 0)
        try image.write(to: folder.appending(path: "Track 04.iso"))
        report.dataTracks = [
            .init(
                number: 4, startLBA: 0, file: "Track 04.iso", sectors: 26,
                mode: .mode1, crc32: String(format: "%08X", CRC32.checksum(of: [UInt8](image), after: 0)))
        ]
        try report.write(to: folder.appending(path: "disc.json"))
        return (try RippedDisc(folder: folder), library)
    }

    @Test func reencodingAlbumKeepsDataTrack() throws {
        let (disc, library) = try dataRip()
        defer { try? FileManager.default.removeItem(at: disc.folder.deletingLastPathComponent()) }
        let first = try DiscEncoder(format: .flac).encode(disc, into: library)
        let album = first[0].deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: album.appending(path: "Data track.iso").path))
        let albumDisc = try RippedDisc(albumReportAt: album.appending(path: "Rip Report.json"))
        let (second, record) = try DiscEncoder(format: .wav).encodeWithRecord(
            albumDisc, into: library.appending(path: "new"))
        #expect(record?.dataTrackFiles == ["Data track.iso"])
        #expect(
            FileManager.default.fileExists(
                atPath: second[0].deletingLastPathComponent().appending(path: "Data track.iso").path))
    }

    @Test func refusesToOverwriteExistingDataWithoutOverwrite() throws {
        let (disc, library) = try dataRip()
        defer { try? FileManager.default.removeItem(at: disc.folder.deletingLastPathComponent()) }
        let encoder = DiscEncoder(format: .flac)
        let album = try #require(try encoder.plannedFiles(disc, into: library).first).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let target = album.appending(path: "Data track.iso")
        let original = Data("Existing unrelated image".utf8)
        try original.write(to: target)
        #expect(throws: (any Error).self) { try encoder.encode(disc, into: library) }
        #expect(try Data(contentsOf: target) == original)
    }

    /// The folder of a data track's files is protected as its image is (review, e2b0a75).
    @Test func keepsAnExistingFilesFolderWithoutOverwrite() throws {
        let (disc, library) = try dataRip()
        defer { try? FileManager.default.removeItem(at: disc.folder.deletingLastPathComponent()) }
        let encoder = DiscEncoder(format: .flac)
        let planned = try encoder.plannedFiles(disc, into: library)
        let album = try #require(planned.first).deletingLastPathComponent()
        let folder = album.appending(path: "Data track", directoryHint: .isDirectory)
        #expect(planned.contains { $0.standardizedFileURL.path == folder.standardizedFileURL.path })
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sentinel = folder.appending(path: "User notes.txt")
        try Data("Keep this".utf8).write(to: sentinel)
        #expect(throws: (any Error).self) { try encoder.encode(disc, into: library) }
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    /// A later rip that takes the folder makes the earlier rip missing, not there twice.
    @Test func replacedReportIsNotTheRipThere() throws {
        let (folder, _) = try PreEmphasisTests().makeRip(emphasized: [])
        let root = folder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = RipHistory(directory: root.appending(path: "history"))
        let file = folder.appending(path: "disc.json")
        let key = try history.record(try RipReport.read(from: file), file: file, hasAudio: true)
        #expect(RipHistory.isThere(try #require(history.entries()[key]), key: key))
        var later = try RipReport.read(from: file)
        later.date += 3600
        try later.write(to: file)
        #expect(!RipHistory.isThere(try #require(history.entries()[key]), key: key))
    }

    /// A repair's report carries the repair's time, so the repair keeps its identity in the
    /// history wherever its folder goes, and stays apart from the rip.
    @Test func repairKeepsItsIdentityWhenMoved() throws {
        let toc = try TOC(audioTrackStarts: [0], leadOutLBA: 100)
        var report = RipReport(
            drive: .init(vendor: "V", product: "P", revision: "1", readOffset: 0, offsetSource: "test"), secure: true,
            toc: toc, tracks: [], ctdb: .init(status: .verified))
        let rip = RipHistory.key(of: report, file: URL(filePath: "/rips/Album/disc.json"))
        report.repaired = Date(timeIntervalSince1970: 1_800_000_000)
        let repaired = RipHistory.key(of: report, file: URL(filePath: "/rips/Album repaired/disc.json"))
        #expect(repaired != rip)
        #expect(RipHistory.key(of: report, file: URL(filePath: "/NAS/Album/disc.json")) == repaired)
        #expect(RipHistory.key(of: report, file: URL(filePath: "/NAS/Album/Rip Report.json")) == repaired)
    }
}
