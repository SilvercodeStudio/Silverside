import Foundation
import Testing

@testable import SilversideKit

struct EACLogTests {
    /// A report of Mingus *Thirteen Pictures* disc 2's TOC, with lines that EAC 1.8 wrote for
    /// real rips (2026-10-30) to match.
    func report() throws -> RipReport {
        let toc = try TOC(ctdbTOCString: "32:47735:62782:96150:208097:222677:243980:275255")
        let drive = RipReport.Drive(
            vendor: "ASUS", product: "BW-16D1HT", revision: "3.10", readOffset: 6, offsetSource: "test")
        var tracks = [RipReport.Track]()
        for track in toc.audioTracks {
            var reported = RipReport.Track(
                number: track.number, file: String(format: "Track %02d.wav", track.number), startLBA: track.startLBA,
                sectors: toc.sectorRange(of: track).count, preEmphasis: false, accurateRip: .notInDatabase)
            reported.crc32 = "9F3BD790"
            reported.accurateRipChecksums = ["24199ABB", "F3728579"]
            tracks.append(reported)
        }
        // Track 1: accurate, with the peak and speed of EAC's Mingus log ("Peak level 96.1 %").
        tracks[0].accurateRip = .accurate
        tracks[0].accurateRipConfidence = [3, 9]
        tracks[0].peak = 31507
        tracks[0].readSeconds = Double(tracks[0].sectors) / 75 / 5.8
        // Track 2: not accurate, as *Reckoning*'s track 3 in EAC's log.
        tracks[1].accurateRip = .notAccurate
        tracks[1].accurateRipChecksums = ["00000000", "D96DA549"]
        tracks[1].accurateRipTop = .init(checksum: "B784EAF7", confidence: 16)
        tracks[1].peak = 32767
        // Track 3: no checksum in AccurateRip, with sectors no reads agreed on, which CTDB repaired.
        tracks[2].accurateRip = .noChecksum
        tracks[2].suspectSectors = [3975, 3976, 4875, 4950, 5025]
        tracks[2].unresolvedSectors = [3975, 3976, 4875, 4950, 5025]
        tracks[2].repairedSamples = 1196
        tracks[2].testCRC32 = "5AF6AF75"
        for index in tracks.indices { tracks[index].ctdbConfidence = 132 }
        var report = RipReport(
            drive: drive, secure: true, toc: toc, tracks: tracks,
            ctdb: .init(status: .repaired, entry: 1, confidence: 132, shift: 0))
        report.ctdb.submissions = 137
        report.program = "Silverside 0.9.2 (abcdef0)"
        return report
    }

    @Test func writesEACsLayout() throws {
        let log = try report().eacStyleLog(folder: URL(filePath: "/rips/Mingus"))
        #expect(log.contains("\r\n") && !log.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        let lines = log.components(separatedBy: "\r\n")
        #expect(lines[0] == "Silverside 0.9.2 (abcdef0)")
        #expect(lines.contains("Used drive  : ASUS    BW-16D1HT   Firmware: 3.10"))
        #expect(lines.contains("Read offset correction                      : 6"))
        #expect(lines.contains("Make use of C2 pointers : No"))
        // The TOC rows, as in EAC's log of the disc.
        #expect(lines.contains("        1  |  0:00.32 | 10:36.03 |        32    |    47734   "))
        #expect(lines.contains("        4  | 21:22.00 | 24:52.47 |     96150    |   208096   "))
        #expect(lines.contains("Track  1"))
        #expect(lines.contains("     Filename /rips/Mingus/Track 01.wav"))
        #expect(lines.contains("     Pre-gap length  0:00:02.32"))
        #expect(lines.contains("     Peak level 96.1 %"))
        #expect(lines.contains("     Peak level 100.0 %"))
        #expect(lines.contains("     Extraction speed 5.8 X"))
        #expect(lines.contains("     Track quality 100.0 %"))
        #expect(lines.contains("     Accurately ripped (confidence 9)  [F3728579]  (AR v2)"))
        #expect(
            lines.contains(
                "     Cannot be verified as accurate (confidence 16)  [D96DA549], AccurateRip returned [B784EAF7]  (AR v2)"
            ))
        #expect(lines.contains("     Track not present in AccurateRip database"))
        // The suspicious positions: one second, and a run of three.
        #expect(lines.contains("     Suspicious position 0:00:53"))
        #expect(lines.contains("     Suspicious position 0:01:05 - 0:01:07"))
        #expect(lines.contains("     Test CRC 5AF6AF75"))
        #expect(lines.contains("     Repaired 1196 samples with CTDB's repair data"))
        #expect(lines.contains(" 5 track(s) not present in the AccurateRip database"))
        #expect(lines.contains(" 1 track(s) could not be verified as accurate"))
        #expect(lines.contains("There were errors, corrected with CTDB's repair data"))
        #expect(lines.contains("[CTDB TOCID: SklljrZhQLU2i9UunYMdtFqSJ7E-] found"))
        #expect(lines.contains("  1   | (132/137) Accurately ripped"))
        #expect(lines.contains("  3   | (132/137) Accurately ripped, after the repair of 1196 samples"))
        #expect(!log.contains("Exact Audio Copy V") && !log.contains("Log checksum"))
    }

    /// The summary's other forms, as EAC writes them.
    @Test func summarizesAsEACDoes() throws {
        var report = try report()
        for index in report.tracks.indices { report.tracks[index].accurateRip = .accurate }
        #expect(report.eacStyleLog(folder: URL(filePath: "/r")).contains("\r\nAll tracks accurately ripped\r\n"))
        for index in report.tracks.indices { report.tracks[index].accurateRip = .notInDatabase }
        #expect(
            report.eacStyleLog(folder: URL(filePath: "/r"))
                .contains("\r\nNone of the tracks are present in the AccurateRip database\r\n"))
        for index in report.tracks.indices { report.tracks[index].accurateRip = .notAccurate }
        #expect(
            report.eacStyleLog(folder: URL(filePath: "/r"))
                .contains(
                    "No tracks could be verified as accurate\r\nYou may have a different pressing from the one(s) in the database"
                ))
        report.ctdb = .init(status: .notInDatabase)
        #expect(
            report.eacStyleLog(folder: URL(filePath: "/r"))
                .contains("[CTDB TOCID: SklljrZhQLU2i9UunYMdtFqSJ7E-] disk not present in database"))
    }

    /// The log follows the Markdown report: written when asked, kept up to date once it is there.
    @Test func followsTheMarkdownReport() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var report = try report()
        let markdown = folder.appending(path: "Rip Report (Disc 2).md")
        let log = folder.appending(path: "Rip Report (Disc 2).log")
        try report.writeReadable(to: markdown)
        #expect(!FileManager.default.fileExists(atPath: log.path))
        try report.writeReadable(to: markdown, eacLog: true)
        #expect(try String(contentsOf: log, encoding: .utf8).contains("Copy CRC 9F3BD790"))
        report.tracks[0].crc32 = "12345678"
        try report.writeReadable(to: markdown)
        #expect(try String(contentsOf: log, encoding: .utf8).contains("Copy CRC 12345678"))
    }

    /// EAC names the checksum with the most submissions, in any record.
    @Test func findsTheTopChecksum() {
        let id = AccurateRipDiscID(audioTrackCount: 1, id1: 1, id2: 2, freedbID: 3)
        let records = [
            AccurateRipRecord(
                discID: id, tracks: [.init(confidence: 9, checksum: 0x7C95_D042, frame450Checksum: 0)]),
            AccurateRipRecord(
                discID: id, tracks: [.init(confidence: 16, checksum: 0xB784_EAF7, frame450Checksum: 0)]),
        ]
        #expect(
            RipReport.AccurateRipEntry.top(trackAt: 0, records: records) == .init(checksum: "B784EAF7", confidence: 16))
        #expect(RipReport.AccurateRipEntry.top(trackAt: 0, records: []) == nil)
    }
}

extension EACLogTests {
    /// A rip writes the log beside its report, and lists it among its files; not when the
    /// setting is off.
    @Test(arguments: [true, false])
    func ripWritesTheLog(writes: Bool) async throws {
        let (toc, samples) = try makeDisc(trackSectors: [800, 900])
        let (result, _, _, root) = try await DiscRipTests().rip(
            web: DiscRipTests.web(toc: toc, samples: samples), configure: { $0.writesEACLog = writes })
        defer { try? FileManager.default.removeItem(at: root) }
        let log = result.folder.appending(path: "Rip Report.log")
        #expect(FileManager.default.fileExists(atPath: log.path) == writes)
        #expect(result.report.files?.contains("Rip Report.log") == writes)
        if writes {
            let text = try String(contentsOf: log, encoding: .utf8)
            #expect(text.contains("All tracks accurately ripped") && text.contains("  2   | (5/5) Accurately ripped"))
            #expect(text.contains("     Peak level ") && text.contains("     Extraction speed "))
        }
    }

    /// De-emphasized tracks are 20-bit in a lossless album, so the sample format says so; an
    /// album with only some of them has both widths.
    @Test(arguments: [([1, 2, 3], "20 Bit"), ([2], "16 and 20 Bit"), ([], "16 Bit")] as [(Set<Int>, String)])
    func sampleFormatOfDeEmphasizedTracks(emphasized: Set<Int>, bits: String) throws {
        let (folder, library) = try PreEmphasisTests().makeRip(emphasized: emphasized)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        var encoder = DiscEncoder(format: .flac)
        encoder.writesEACLog = true
        let (files, record) = try encoder.encodeWithRecord(try RippedDisc(folder: folder), into: library)
        #expect(Set(record?.deEmphasizedTracks ?? []) == emphasized)
        let log = try String(
            contentsOf: try #require(files.first).deletingLastPathComponent().appending(path: "Rip Report.log"),
            encoding: .utf8)
        #expect(log.contains("44.100 Hz; \(bits); Stereo"))
    }
}
