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

    /// *A Clockwork Orange* (East Side Digital): the data track's last 152 sectors, its
    /// post-gap, cannot be read, and the ASUS stops answering there. Its ISO 9660 volume ends
    /// 302 sectors before the track, so the reader stops there, and the image has zeros after,
    /// as a drive that reads them gives.
    @Test func readsTheDataTrackToTheEndOfItsFileSystem() throws {
        let (toc, samples) = try Self.disc()
        let drive = SimulatedDrive(toc: toc, samples: samples)
        let data = toc.tracks[2]
        // A session-2 volume counts from the disc's start: 240 sectors of the track's 300.
        var pvd = [UInt8](repeating: 0, count: 2048)
        pvd[0] = 1
        pvd.replaceSubrange(1..<6, with: Array("CD001".utf8))
        let size = UInt32(data.startLBA + 240)
        pvd.replaceSubrange(80..<84, with: (0..<4).map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) })
        drive.dataSectors[data.startLBA + 16] = pvd
        for lba in (data.startLBA + 240)..<(data.startLBA + 300) {
            drive.dataSectors[lba] = [UInt8](repeating: 0, count: 2048)
        }
        drive.unreadableSectors = Set((data.startLBA + 250)..<(data.startLBA + 300))
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "Track 03.iso")
        let saved = try DataTrackReader.read(data, in: toc, drive: drive, to: url, giveUpAfter: 5)
        #expect(saved.skippedSectors == 60 && saved.unreadableSectors == nil && saved.sectors == 300)
        // The same file as a drive that reads the empty sectors gives.
        drive.unreadableSectors = []
        drive.dataSectors[data.startLBA + 16] = [UInt8](repeating: 0, count: 2048)
        let whole = try DataTrackReader.read(data, in: toc, drive: drive, to: root.appending(path: "whole.iso"))
        #expect(whole.skippedSectors == nil)
        var expected = try [UInt8](Data(contentsOf: root.appending(path: "whole.iso")))
        expected.replaceSubrange((16 * 2048)..<(17 * 2048), with: pvd)
        #expect(try [UInt8](Data(contentsOf: url)) == expected)
    }

    /// The end of an Apple partition map's last partition (a Mac's HFS) counts too, as on *Mirrorball*.
    @Test func findsTheEndOfAnHFSPartition() {
        var bytes = [UInt8](repeating: 0, count: 26 * 2048)
        func put(_ value: UInt32, at offset: Int) {
            bytes.replaceSubrange(
                offset..<(offset + 4), with: (0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        for entry in 1...2 {
            bytes[512 * entry] = 0x50
            bytes[512 * entry + 1] = 0x4D
            put(2, at: 512 * entry + 4)
        }
        put(1, at: 512 + 8)
        put(2, at: 512 + 12)
        put(165, at: 1024 + 8)
        put(108_197, at: 1024 + 12)
        #expect(DataTrackReader.fileSystemEnd(of: bytes, startLBA: 308_636, sectors: 27_393) == 27_091)
        #expect(DataTrackReader.fileSystemEnd(of: bytes, startLBA: 308_636, sectors: 20_000) == nil)
        #expect(
            DataTrackReader.fileSystemEnd(of: [UInt8](repeating: 0, count: 26 * 2048), startLBA: 0, sectors: 100) == nil
        )
    }

    /// A drive that cannot read the data session fails every sector of it: the reader stops
    /// after a run of failures, not after retrying each sector of the track.
    @Test func stopsWhenTheDriveCannotReadTheDataTrack() throws {
        let (toc, samples) = try Self.disc()
        let drive = SimulatedDrive(toc: toc, samples: samples)
        let data = toc.tracks[2]
        drive.unreadableSectors = Set((data.startLBA + 40)..<(data.startLBA + 300))
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "Track 03.iso")
        #expect(throws: DataTrackError.unreadable(track: 3, sectors: 50)) {
            try DataTrackReader.read(data, in: toc, drive: drive, to: url, giveUpAfter: 50)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // A shorter run of failures is kept as zeros.
        drive.unreadableSectors = Set((data.startLBA + 40)..<(data.startLBA + 60))
        #expect(
            try DataTrackReader.read(data, in: toc, drive: drive, to: url, giveUpAfter: 50).unreadableSectors?.count
                == 20)
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
        settings.dataTracks = saves ? .save : .skip
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

    /// *A Clockwork Orange* in the ASUS: the data track fails, but the audio's rip is whole and
    /// its report says why the data track was not saved. Save Data Track reads it later, into
    /// the rip's folder and, once the rip is encoded, the album folder, and each report gets it.
    @Test func keepsTheAudioWhenTheDataTrackFailsAndSavesItLater() async throws {
        let (toc, samples) = try Self.disc()
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 6)
        drive.readsSessionLeadOut = true
        let data = toc.tracks[2]
        drive.unreadableSectors = Set(toc.sectorRange(of: data))
        var settings = Settings()
        settings.rips = root.path
        settings.dataTracks = .save
        var options = DiscRipOptions(settings: settings)
        options.offline = true
        options.readOffset = 6
        options.manualRelease = .manual(toc: toc)
        let rip = DiscRip(
            drive: drive, identity: DriveIdentity(vendor: "SIM", product: "DRIVE", revision: "1.0"),
            settings: settings, options: options,
            profiles: try DriveProfileStore(url: root.appending(path: "DriveProfiles.json")))
        let result = try await rip.run()
        let file = result.folder.appending(path: "disc.json")
        let report = try RipReport.read(from: file)
        #expect(report.dataTracks == nil && report.dataTrackFailures?.map(\.number) == [3])
        #expect(report.tracks.count == 2 && report.markdown.contains("Data track 3: not saved"))

        // Encoded first, then saved: the album gets the image and the files on it.
        var encoder = DiscEncoder(format: .flac)
        encoder.allowsUnverified = true
        let (files, record) = try encoder.encodeWithRecord(
            try RippedDisc(folder: result.folder), into: root.appending(path: "library"))
        try record?.save(inReportAt: file)
        let album = files[0].deletingLastPathComponent()
        try MetadataEdits(album: "Kept").save(inDiscJSONOf: result.folder)
        drive.unreadableSectors = []
        #expect(throws: DataTrackError.notData(track: 2)) {
            try encoder.saveDataTrack(2, reportAt: file, drive: drive)
        }
        let saved = try encoder.saveDataTrack(3, reportAt: file, drive: drive)
        #expect(saved.file == "Track 03.iso")
        let updated = try RipReport.read(from: file)
        #expect(updated.dataTracks?.map(\.number) == [3] && updated.dataTrackFailures == nil)
        #expect(
            updated.files?.contains("Track 03.iso") == true && updated.encoding?.dataTrackFiles == ["Data track.iso"])
        // The keys a report does not have stay.
        #expect(MetadataEdits.read(fromDiscJSONOf: result.folder)?.album == "Kept")
        #expect(
            try Data(contentsOf: album.appending(path: "Data track.iso"))
                == Data(contentsOf: result.folder.appending(path: "Track 03.iso")))
        let albumReport = try RipReport.read(from: album.appending(path: "Rip Report.json"))
        #expect(albumReport.dataTracks?.count == 1 && albumReport.encoding?.dataTrackFiles == ["Data track.iso"])

        // Once the rip's WAV files are gone, the library's report takes it in its album folder.
        try FileManager.default.removeItem(at: album.appending(path: "Data track.iso"))
        try RipReport.update(reportAt: album.appending(path: "Rip Report.json")) {
            $0.dataTracks = nil
            $0.encoding?.dataTrackFiles = nil
        }
        let again = try encoder.saveDataTrack(3, reportAt: album.appending(path: "Rip Report.json"), drive: drive)
        #expect(again.file == "Data track.iso" && again.crc32 == saved.crc32)
        let library = try RipReport.read(from: album.appending(path: "Rip Report.json"))
        #expect(
            library.dataTracks?.first?.file == "Data track.iso"
                && library.encoding?.dataTrackFiles == ["Data track.iso"])
        #expect(FileManager.default.fileExists(atPath: album.appending(path: "Data track.iso").path))
    }

    /// With the setting "ask", the rip asks once as it starts; the answer decides.
    @Test(arguments: [true, false])
    func asksWhetherToSaveTheDataTrack(answer: Bool) async throws {
        let (toc, samples) = try Self.disc()
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = Settings()
        settings.rips = root.path
        var options = DiscRipOptions(settings: settings)
        #expect(options.dataTracks == .ask)
        options.offline = true
        options.readOffset = 6
        options.manualRelease = .manual(toc: toc)
        var rip = DiscRip(
            drive: SimulatedDrive(toc: toc, samples: samples, readOffset: 6),
            identity: DriveIdentity(vendor: "SIM", product: "DRIVE", revision: "1.0"), settings: settings,
            options: options, profiles: try DriveProfileStore(url: root.appending(path: "DriveProfiles.json")))
        let asked = DiscRipEvents()
        rip.chooseDataTracks = { tracks in
            asked.append(.controlBits("\(tracks.map(\.number))"))
            return answer
        }
        let result = try await rip.run()
        #expect(asked.list.count == 1)
        #expect((result.report.dataTracks != nil) == answer)
    }
}
