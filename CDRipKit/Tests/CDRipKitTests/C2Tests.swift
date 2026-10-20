import Foundation
import Testing

@testable import CDRipKit

struct C2Tests {
    /// The three-track disc of `TrackRipperTests`, and a secure ripper whose drive
    /// returns the given sectors wrong every time.
    func setUp(corrupt: Set<Int>, readsC2: Bool = true, withRecords: Bool = true) throws -> (
        secure: SecureRipper, toc: TOC, samples: [UInt32], drive: SimulatedDrive
    ) {
        let (toc, samples, record) = try TrackRipperTests().disc()
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: SecureRipperTests.driveOffset)
        drive.corruptSectors = corrupt
        drive.reportsC2 = true
        let reader = AudioReader(drive: drive, toc: toc, readOffset: SecureRipperTests.driveOffset, canOverread: false)
        var ripper = TrackRipper(reader: reader, records: withRecords ? [record] : [])
        ripper.readsC2 = readsC2
        var secure = SecureRipper(ripper: ripper)
        secure.cacheFlushSectors = toc.leadOutLBA
        secure.maximumRounds = 4
        return (secure, toc, samples, drive)
    }

    @Test func flagsTheSamplesOfDamagedSectors() throws {
        let (secure, toc, _, _) = try setUp(corrupt: [600])
        let reader = secure.ripper.reader
        let all = 0..<(toc.leadOutLBA * 588)
        let read = try reader.readSamplesWithC2(all)
        // The drive's offset moves the data, but the flags stay with their samples.
        #expect(read.flagged == Array((600 * 588)..<(601 * 588)))
        #expect(read.samples == (try reader.readSamples(all)))
    }

    @Test func reportsC2OnlyWhenAsked() throws {
        let (secure, toc, _, _) = try setUp(corrupt: [600], readsC2: false)
        #expect(try secure.ripper.rip(toc.tracks[1]).c2Samples == nil)
        let (withC2, _, _, _) = try setUp(corrupt: [600])
        #expect(try withC2.ripper.rip(toc.tracks[1]).c2Samples == Array((140 * 588)..<(141 * 588)))
    }

    /// An error that reads the same every time is still suspect when the drive flags it.
    @Test func reReadsSectorsWithC2Errors() throws {
        let (secure, toc, _, _) = try setUp(corrupt: [600])
        let rip = try secure.rip(toc.tracks[1])
        #expect(rip.status == .suspect)
        #expect(rip.c2Sectors == [140] && rip.suspectSectors == [140])
        #expect(rip.rounds > 0)
    }

    /// Four sectors that read wrong every time, at the same place in four rows: 4 errors in
    /// each of their columns, too many for 6 syndromes, unless C2 shows where they are.
    @Test func repairsWithC2Erasures() async throws {
        let corrupt: Set<Int> = [500, 510, 520, 530]
        for readsC2 in [false, true] {
            let (secure, toc, samples, _) = try setUp(corrupt: corrupt, readsC2: readsC2, withRecords: false)
            let rips = try toc.audioTracks.map { try secure.rip($0) }
            let layout = CTDBLayout(toc: toc)
            let syndromes = CTDB.syndromes(of: samples, layout: layout, shift: 0, count: 6)
            let entry = CTDBEntry(
                id: 1, confidence: 5, crc32: CTDB.discCRC(of: samples, layout: layout),
                trackCRCs: CTDB.trackCRCs(of: samples, toc: toc, layout: layout),
                repairDataURL: URL(string: "https://example.org/parity"), syndromeCount: 6,
                column0Syndromes: Array(syndromes[0..<6]))
            var repairer = DiscRepairer(toc: toc, records: [], entries: [entry])
            repairer.repairData = { _ in syndromes }
            let result = try await repairer.repair(rips.map(TrackAudio.init))
            if readsC2 {
                guard case .repaired(_, _, let changed) = result.outcome else {
                    Issue.record("Not repaired with C2: \(result.outcome)")
                    continue
                }
                #expect(changed.count == 4 * 588)
            } else {
                #expect(result.outcome == .notVerified)
            }
        }
    }
}
