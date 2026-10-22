import Testing

@testable import SilversideKit

struct AccurateRipChecksumTests {
    /// A track where one sample at `position` (1-based) has the value 1.
    func impulse(at position: Int, count: Int) -> [UInt32] {
        var samples = [UInt32](repeating: 0, count: count)
        samples[position - 1] = 1
        return samples
    }

    func checksum(_ samples: [UInt32], first: Bool = false, last: Bool = false) -> AccurateRipChecksum {
        AccurateRipAccumulator.checksum(of: samples[...], isFirstTrack: first, isLastTrack: last)
    }

    @Test func eachSampleIsWeightedByItsPosition() {
        #expect(checksum([3, 5]) == AccurateRipChecksum(v1: 3 * 1 + 5 * 2, v2: 3 * 1 + 5 * 2))
    }

    @Test func v2AddsTheHighWordOfEachProduct() {
        // 0xFFFFFFFF * 2 = 0x1_FFFFFFFE. v1 keeps the low word. v2 adds the high word.
        #expect(checksum([0, 0xFFFF_FFFF]) == AccurateRipChecksum(v1: 0xFFFF_FFFE, v2: 0xFFFF_FFFF))
    }

    @Test func firstTrackSkipsTheFirst2939Samples() {
        let count = 20 * CDDA.samplesPerSector
        #expect(checksum(impulse(at: 2939, count: count), first: true).v1 == 0)
        #expect(checksum(impulse(at: 2940, count: count), first: true).v1 == 2940)
    }

    @Test func lastTrackSkipsTheLast2940Samples() {
        let count = 20 * CDDA.samplesPerSector
        #expect(checksum(impulse(at: count - 2940, count: count), last: true).v1 == UInt32(count - 2940))
        #expect(checksum(impulse(at: count - 2939, count: count), last: true).v1 == 0)
    }

    @Test func partsGiveTheSameResultAsOneCall() throws {
        let (_, samples) = try makeDisc(trackSectors: [30])
        var accumulator = AccurateRipAccumulator(sampleCount: samples.count, isFirstTrack: true, isLastTrack: true)
        var start = 0
        for size in [1, 587, 588, 5000, 1] {
            let part = samples[start..<(start + size)]
            accumulator.add(part[...])
            start += size
        }
        #expect(!accumulator.isComplete)
        let rest = samples[start...]
        accumulator.add(rest[...])
        #expect(accumulator.checksum == checksum(samples, first: true, last: true))
    }
}
