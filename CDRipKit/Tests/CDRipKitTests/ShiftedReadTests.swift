import Testing

@testable import CDRipKit

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
}
