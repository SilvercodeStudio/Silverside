import Foundation
import Testing

@testable import CDRipKit

/// Sectors that the drive cannot read at all. They must not stop a rip.
struct UnreadableSectorTests {
    @Test func readsSilenceWhereASectorFails() throws {
        let (toc, samples) = try makeDisc(trackSectors: [30, 40])
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 100)
        drive.unreadableSectors = [45]
        var reader = AudioReader(drive: drive, toc: toc, readOffset: 100, canOverread: false)
        reader.unreadableRetries = 2
        let all = 0..<(toc.leadOutLBA * 588)
        let read = try reader.read(all, withC2: false)
        // Sector 45 of the drive holds the true samples 100 before 45 * 588.
        let lost = (45 * 588 - 100)..<(46 * 588 - 100)
        #expect(read.unreadable == Array(lost))
        #expect(read.samples[lost].allSatisfy { $0 == 0 })
        let (before, after) = (0..<lost.lowerBound, lost.upperBound..<(70 * 588 - 100))
        #expect(read.samples[before] == samples[before] && read.samples[after] == samples[after])
    }

    /// A sector that no read can read stays unresolved: its silence is not a version that
    /// reads agree on.
    @Test func leavesASectorThatNeverReadsUnresolved() throws {
        let (toc, samples) = try makeDisc(trackSectors: [460, 470, 460])
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 6)
        drive.unreadableSectors = [600]
        var reader = AudioReader(drive: drive, toc: toc, readOffset: 6, canOverread: false)
        reader.unreadableRetries = 1
        var secure = SecureRipper(ripper: TrackRipper(reader: reader, records: []))
        secure.cacheFlushSectors = toc.leadOutLBA
        let rip = try secure.rip(toc.tracks[1])
        #expect(rip.status == .suspect)
        #expect(rip.unreadableSectors == [139, 140] && rip.unresolvedSectors == [139, 140])
        #expect(rip.versionCounts == [139: 0, 140: 0])
        // The re-reads stop once they give nothing new, well before the limit.
        #expect(rip.rounds < secure.maximumRounds)
    }

    /// Four unreadable sectors, one in each of four rows at the same place: their samples
    /// are erasures for CTDB, which needs 6 syndromes for 4 erasures and has them.
    @Test func repairsSectorsThatCannotBeRead() async throws {
        let (toc, samples, _) = try TrackRipperTests().disc()
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: SecureRipperTests.driveOffset)
        drive.unreadableSectors = [600, 610, 620, 630]
        var reader = AudioReader(drive: drive, toc: toc, readOffset: SecureRipperTests.driveOffset, canOverread: false)
        reader.unreadableRetries = 1
        var secure = SecureRipper(ripper: TrackRipper(reader: reader, records: []))
        secure.cacheFlushSectors = toc.leadOutLBA
        secure.maximumRounds = 2
        let rips = try toc.audioTracks.map { try secure.rip($0) }
        #expect(rips[1].unreadableSamples.count == 4 * 588)

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
        guard case .repaired(_, _, let changed) = result.outcome else {
            Issue.record("Not repaired: \(result.outcome)")
            return
        }
        #expect(changed.count == 4 * 588)
    }
}
