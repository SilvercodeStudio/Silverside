import Foundation
import Testing

@testable import SilversideKit

struct RipReportTests {
    @Test func readsWhatItWrites() throws {
        let toc = try TOC(audioTrackStarts: [0, 20867], leadOutLBA: 56350)
        let drive = RipReport.Drive(
            vendor: "ASUS", product: "BW-16D1HT", revision: "3.10", readOffset: 6, offsetSource: "confirmed by rips")
        let tracks = [
            RipReport.Track(
                number: 1, file: "Track 01.wav", startLBA: 0, sectors: 20867, preEmphasis: false,
                accurateRip: .accurate,
                accurateRipConfidence: [55, 87], ctdbConfidence: 299),
            RipReport.Track(
                number: 2, file: "Track 02.wav", startLBA: 20867, sectors: 35483, preEmphasis: false,
                accurateRip: .notAccurate, fullReads: 4, rereadRounds: 16, suspectSectors: [7, 8],
                unresolvedSectors: [8], ctdbConfidence: 299, repairedSamples: 1176),
        ]
        let report = RipReport(
            date: Date(timeIntervalSince1970: 1_800_000_000), drive: drive, secure: true, toc: toc, tracks: tracks,
            ctdb: .init(status: .repaired, entry: 869169, confidence: 299, shift: 0))
        let url = FileManager.default.temporaryDirectory.appending(path: "RipReport-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try report.write(to: url)
        #expect(try RipReport.read(from: url) == report)
        // The archive's disc.json files use the same names for the TOC and the disc ID.
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(object?["toc"] as? String == "0:20867:56350")
        #expect(object?["musicBrainzDiscID"] as? String == toc.musicBrainzDiscID)
    }

    @Test func isVerifiedOnlyIfEveryTrackIsProved() throws {
        let toc = try TOC(audioTrackStarts: [0, 20867], leadOutLBA: 56350)
        let drive = RipReport.Drive(
            vendor: "SIM", product: "DRIVE", revision: "1.0", readOffset: 6, offsetSource: "--offset")
        let tracks = [
            RipReport.Track(
                number: 1, file: "Track 01.wav", startLBA: 0, sectors: 20867, preEmphasis: false,
                accurateRip: .accurate),
            RipReport.Track(
                number: 2, file: "Track 02.wav", startLBA: 20867, sectors: 35483, preEmphasis: false,
                accurateRip: .notAccurate),
        ]
        var report = RipReport(
            drive: drive, secure: true, toc: toc, tracks: tracks, ctdb: .init(status: .notVerified))
        #expect(!report.isVerified)
        // CTDB proves a track by its track CRC, or the whole disc.
        report.tracks[1].ctdbConfidence = 12
        #expect(report.isVerified)
        report.tracks[1].ctdbConfidence = nil
        report.ctdb.status = .repaired
        #expect(report.isVerified)
        // A hidden track whose reads all differ is not verified.
        report.hiddenTrack = .init(file: "Track 00.wav", sectors: 300, peak: 900, readsAgree: false, reads: 5)
        #expect(!report.isVerified)
    }

    /// The archive keeps a rip's report inside its manifest, under "ripReport", with the release beside it.
    @Test func readsAReportFromAnArchiveManifest() throws {
        let (toc, _) = try makeDisc(trackSectors: [800, 900])
        let report = RipReport(
            drive: .init(vendor: "V", product: "P", revision: "1", readOffset: 6, offsetSource: "test"), secure: true,
            toc: toc, tracks: [], ctdb: .init(status: .verified))
        let folder = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let nested = try JSONSerialization.jsonObject(with: encoder.encode(report))
        let release = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MusicBrainzRelease.manual(toc: toc)))
        let manifest: [String: Any] = [
            "complete": true, "toc": toc.ctdbTOCString, "ripReport": nested, "release": release,
        ]
        let file = folder.appending(path: "Rip Report.json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: file)
        let read = try RipReport.read(from: file)
        #expect(read.ctdb.status == .verified && read.toc == toc.ctdbTOCString)
        #expect(read.release?.isManual == true)
        try JSONSerialization.data(withJSONObject: ["complete": true, "toc": toc.ctdbTOCString]).write(to: file)
        #expect(throws: (any Error).self) { try RipReport.read(from: file) }
    }

    /// The checksums that EAC and XLD print, so rips can be compared across programs, and
    /// the test read's, kept with the media type and read back.
    @Test func keepsChecksumsAndTheMediaType() throws {
        let toc = try TOC(audioTrackStarts: [0, 800], leadOutLBA: 1700)
        let (_, samples) = try makeDisc(trackSectors: [800, 900])
        var track = RipReport.Track(
            number: 1, file: "Track 01.wav", startLBA: 0, sectors: 800, preEmphasis: false, accurateRip: .accurate)
        let audio = Array(samples[0..<(800 * CDDA.samplesPerSector)])
        track.recordChecksums(of: audio, isFirstTrack: true, isLastTrack: false)
        #expect(track.crc32 == CRC32.hex(CRC32.checksum(of: audio[...])))
        #expect(track.crc32?.count == 8 && track.accurateRipChecksums?.count == 2)
        // Silent samples do not count in the skip-zero checksum.
        var padded = audio
        padded += [UInt32](repeating: 0, count: 588)
        var paddedTrack = track
        paddedTrack.recordChecksums(of: padded, isFirstTrack: true, isLastTrack: false)
        #expect(paddedTrack.crc32SkipZero == track.crc32SkipZero && paddedTrack.crc32 != track.crc32)
        track.testCRC32 = "DEADBEEF"
        track.testReadMatches = false
        var report = RipReport(
            date: Date(timeIntervalSince1970: 1_800_000_000),
            drive: .init(vendor: "SIM", product: "DRIVE", revision: "1.0", readOffset: 6, offsetSource: "--offset"),
            secure: true, toc: toc, tracks: [track], ctdb: .init(status: .notChecked))
        report.media = .recordable
        report.started = Date(timeIntervalSince1970: 1_799_998_273)
        report.ctdbSeconds = 130
        report.tracks[0].seconds = 591
        let url = FileManager.default.temporaryDirectory.appending(path: "RipReport-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try report.write(to: url)
        #expect(try RipReport.read(from: url) == report)
        let markdown = report.markdown
        #expect(markdown.contains("| Media | CD-R |"))
        #expect(
            markdown.contains("## Checksums")
                && markdown.contains("| 1 | \(track.crc32!) | \(track.crc32SkipZero!) | DEADBEEF **differs** |"))
        #expect(markdown.contains("Test and copy: the second read of track 1 differed from the copy."))
        #expect(markdown.contains("the tracks took 9:51; the CTDB check 2:10; the rip 28:47 in all."))
        #expect(RipReport.minutes(3_725) == "1:02:05")
    }
}
