import Foundation
import Testing

@testable import SilversideKit

/// An Enhanced CD: audio in the first session, a data track in the second.
struct EnhancedCDTests {
    /// Two audio tracks (sectors 0 to 1700), then the session gap, then a data track of 300 sectors.
    static func disc() throws -> (toc: TOC, samples: [UInt32]) {
        let toc = try TOC(
            tracks: [
                .init(number: 1, startLBA: 0),
                .init(number: 2, startLBA: 800),
                .init(number: 3, startLBA: 1700 + CDDA.sessionGapSectors, kind: .data, session: 2),
            ], leadOutLBA: 1700 + CDDA.sessionGapSectors + 300)
        // Audio through the first session's lead-out too, where a drive that reads it finds the tail.
        var generator = SplitMix64(state: 3)
        var samples = (0..<((1700 + 20) * 588)).map { _ in UInt32.random(in: 1...UInt32.max, using: &generator) }
        samples += [UInt32](repeating: 0, count: toc.leadOutLBA * 588 - samples.count)
        return (toc, samples)
    }

    @Test func readsTheLastTrackIntoTheLeadOutWhereTheDriveCan() throws {
        let (toc, samples) = try Self.disc()
        let last = (800 * 588)..<(1700 * 588)
        for readsLeadOut in [true, false] {
            let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 6)
            drive.readsSessionLeadOut = readsLeadOut
            var reader = AudioReader(drive: drive, toc: toc, readOffset: 6, canOverread: false)
            reader.readableLeadOut = AudioReader.sessionLeadOut(of: toc, drive: drive)
            #expect((reader.readableLeadOut != nil) == readsLeadOut)
            let read = try reader.readSamples(last)
            #expect(read.dropLast(6) == samples[last].dropLast(6))
            // Without the lead-out, the last 6 samples are silence.
            #expect(Array(read.suffix(6)) == (readsLeadOut ? Array(samples[last].suffix(6)) : [0, 0, 0, 0, 0, 0]))
        }
    }

    @Test func savesTheDataTrackAsAnISOImage() throws {
        let (toc, samples) = try Self.disc()
        let drive = SimulatedDrive(toc: toc, samples: samples)
        let data = toc.tracks[2]
        drive.unreadableSectors = [data.startLBA + 30]
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "Track 03.iso")
        var fractions = [Double]()
        let saved = try DataTrackReader.read(data, in: toc, drive: drive, to: url) { fractions.append($0) }
        let bytes = try [UInt8](Data(contentsOf: url))
        #expect(bytes.count == 300 * 2048 && saved.sectors == 300 && saved.mode == .mode1)
        #expect(saved.unreadableSectors == [30])
        #expect(bytes[(30 * 2048)..<(31 * 2048)].allSatisfy { $0 == 0 })
        let expected = (data.startLBA..<(data.startLBA + 300)).flatMap { lba in
            (0..<2048).map { lba == data.startLBA + 30 ? 0 : SimulatedDrive.dataByte(lba: lba, index: $0) }
        }
        #expect(bytes == expected)
        #expect(saved.crc32 == String(format: "%08X", CRC32.checksum(of: bytes, after: 0)))
        #expect(fractions.last == 1)
    }

    /// A rip saves the data track and reads the last track to its end; the encoding copies
    /// the ISO image into the album folder. With the setting off, there is none.
    @Test(arguments: [true, false])
    func ripSavesTheDataTrack(saves: Bool) async throws {
        let (toc, samples) = try Self.disc()
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 6)
        drive.readsSessionLeadOut = true
        var settings = Settings()
        settings.rips = root.path
        settings.saveDataTracks = saves
        var options = DiscRipOptions(settings: settings)
        options.offline = true
        options.readOffset = 6
        options.manualRelease = .manual(toc: toc)
        let rip = DiscRip(
            drive: drive, identity: DriveIdentity(vendor: "SIM", product: "DRIVE", revision: "1.0"),
            settings: settings, options: options,
            profiles: try DriveProfileStore(url: root.appending(path: "DriveProfiles.json")))
        let result = try await rip.run()
        let report = try RipReport.read(from: result.folder.appending(path: "disc.json"))
        #expect(report.paddedEdges == nil)
        #expect(
            try WAVFile.read(result.folder.appending(path: "Track 02.wav"))
                == Array(samples[(800 * 588)..<(1700 * 588)]))
        guard saves else {
            #expect(report.dataTracks == nil)
            return
        }
        let saved = try #require(report.dataTracks?.first)
        #expect(saved.number == 3 && saved.file == "Track 03.iso" && report.files?.contains("Track 03.iso") == true)
        #expect(report.markdown.contains("Data track 3 (Mode 1"))

        var encoder = DiscEncoder(format: .flac)
        encoder.allowsUnverified = true
        let (files, record) = try encoder.encodeWithRecord(
            try RippedDisc(folder: result.folder), into: root.appending(path: "library"))
        let iso = files[0].deletingLastPathComponent().appending(path: "Data track.iso")
        #expect(record?.dataTrackFiles == ["Data track.iso"])
        #expect(try Data(contentsOf: iso) == Data(contentsOf: result.folder.appending(path: "Track 03.iso")))
    }
}
