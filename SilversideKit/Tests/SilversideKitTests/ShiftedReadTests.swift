import Testing

@testable import SilversideKit

/// Reads that lose their place, as a drive can on a scratch: from some sector on, the
/// data comes from a few hundred samples further on.
struct ShiftedReadTests {
    let tests = SecureRipperTests()

    /// The second read slips. Without the check, about 330 sectors of it would be suspect.
    @Test func leavesOutAShiftedRead() throws {
        let (secure, toc, _, drive) = try tests.setUp(corrupt: [500])
        drive.slips = [.init(sector: 600, shift: 300, onPass: 2)]
        let rip = try secure.rip(toc.tracks[1])
        #expect(rip.shiftedReads == [300])
        #expect(!rip.firstReadWasShifted)
        #expect(rip.status == .consistentButNotAccurate)
        #expect(rip.suspectSectors.isEmpty)
    }

    /// The first read slips: the next two reads agree with each other, and replace it.
    @Test(arguments: [false, true])
    func replacesAShiftedFirstRead(withRecords: Bool) throws {
        let (secure, toc, samples, drive) = try tests.setUp(withRecords: withRecords)
        drive.slips = [.init(sector: 600, shift: 300, onPass: 1)]
        let track = toc.tracks[1]
        let rip = try secure.rip(track)
        #expect(rip.firstReadWasShifted)
        #expect(rip.shiftedReads == [300])
        #expect(rip.samples[...] == tests.trueSamples(of: track, in: toc, samples))
        #expect(rip.status == (withRecords ? .accurate(v1Confidence: 0, v2Confidence: 4) : .consistent))
    }

    /// Damage over a long run of sectors changes data in place, so no shift explains it.
    @Test func doesNotTakeDamageForAShift() throws {
        var (secure, toc, _, _) = try tests.setUp(unstable: Set(600..<640), withRecords: false)
        secure.maximumRounds = 2
        let rip = try secure.rip(toc.tracks[1])
        #expect(rip.shiftedReads.isEmpty)
        #expect(rip.suspectSectors == Array(140..<180))
    }

    /// Two reads that slip at different places do not agree with each other, so neither
    /// replaces the first read. The third read, which does not slip, confirms it.
    @Test func doesNotTakeTwoDifferentSlipsForAgreement() throws {
        let (secure, toc, samples, drive) = try tests.setUp(withRecords: false)
        drive.slips = [.init(sector: 600, shift: 300, onPass: 2), .init(sector: 650, shift: 500, onPass: 3)]
        let track = toc.tracks[1]
        let rip = try secure.rip(track)
        #expect(!rip.firstReadWasShifted)
        #expect(rip.shiftedReads == [300, 500])
        #expect(rip.status == .consistent && rip.suspectSectors.isEmpty)
        #expect(rip.samples[...] == tests.trueSamples(of: track, in: toc, samples))
    }

    /// When every read after the first loses its place, nothing confirms the first read.
    @Test func isSuspectWhenNoReadConfirmsTheFirst() throws {
        let (secure, toc, _, drive) = try tests.setUp(withRecords: false)
        drive.slips = (2...4).map { .init(sector: 600 + 10 * $0, shift: 100 * $0, onPass: $0) }
        let rip = try secure.rip(toc.tracks[1])
        #expect(rip.status == .suspect)
        #expect(rip.shiftedReads == [200, 300, 400] && !rip.firstReadWasShifted)
        #expect(rip.suspectSectors.isEmpty && rip.unresolvedSectors.isEmpty)
    }
}
