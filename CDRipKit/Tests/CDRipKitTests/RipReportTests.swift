import Foundation
import Testing

@testable import CDRipKit

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
}
