/// The AccurateRip v1 and v2 checksums of one track.
///
/// Both checksums are sums of one term for each sample, so the checksum of a
/// track is the sum of the checksums of its parts. `+` and `-` wrap, as the sums do.
public struct AccurateRipChecksum: Hashable, Sendable {
    public var v1: UInt32
    public var v2: UInt32

    public static let zero = AccurateRipChecksum(v1: 0, v2: 0)

    public static func + (left: Self, right: Self) -> Self {
        Self(v1: left.v1 &+ right.v1, v2: left.v2 &+ right.v2)
    }

    public static func - (left: Self, right: Self) -> Self {
        Self(v1: left.v1 &- right.v1, v2: left.v2 &- right.v2)
    }
}

/// Calculates AccurateRip checksums from a track's samples, in one or more parts.
///
/// AccurateRip ignores the first 5 sectors (less one sample) of the first track
/// and the last 5 sectors of the last track, because drive offsets make those
/// samples unreliable.
public struct AccurateRipAccumulator: Sendable {
    private static let skippedSamples = 5 * CDDA.samplesPerSector

    // The checksum includes samples at these 1-based positions.
    private let firstPosition: UInt32
    private let lastPosition: UInt32
    private let sampleCount: Int

    private var nextPosition: UInt32 = 1
    private var v1: UInt32 = 0
    private var v2: UInt32 = 0

    public init(sampleCount: Int, isFirstTrack: Bool, isLastTrack: Bool) {
        precondition(sampleCount >= 0 && sampleCount < Int(UInt32.max))
        self.sampleCount = sampleCount
        firstPosition = UInt32(isFirstTrack ? Self.skippedSamples : 1)
        lastPosition = UInt32(isLastTrack ? max(sampleCount - Self.skippedSamples, 0) : sampleCount)
    }

    public mutating func add(_ samples: ArraySlice<UInt32>) {
        precondition(Int(nextPosition) - 1 + samples.count <= sampleCount, "More samples than the track has")
        var position = nextPosition
        for index in samples.indices {
            if position >= firstPosition && position <= lastPosition {
                let sample = samples[index]
                v1 &+= sample &* position
                let product = UInt64(sample) * UInt64(position)
                v2 &+= UInt32(truncatingIfNeeded: product) &+ UInt32(truncatingIfNeeded: product >> 32)
            }
            position &+= 1
        }
        nextPosition = position
    }

    public var isComplete: Bool { Int(nextPosition) - 1 == sampleCount }

    public var checksum: AccurateRipChecksum {
        precondition(isComplete, "Not all samples of the track were added")
        return AccurateRipChecksum(v1: v1, v2: v2)
    }

    /// The part of a track's checksums that `samples` give, where `samples[0]` is
    /// at the 1-based `position` in a track of `sampleCount` samples.
    public static func contribution(
        of samples: ArraySlice<UInt32>, at position: Int, sampleCount: Int, isFirstTrack: Bool, isLastTrack: Bool
    ) -> AccurateRipChecksum {
        precondition(position >= 1 && position - 1 + samples.count <= sampleCount)
        var accumulator = AccurateRipAccumulator(
            sampleCount: sampleCount, isFirstTrack: isFirstTrack, isLastTrack: isLastTrack)
        accumulator.nextPosition = UInt32(position)
        accumulator.add(samples)
        return AccurateRipChecksum(v1: accumulator.v1, v2: accumulator.v2)
    }

    public static func checksum(
        of samples: ArraySlice<UInt32>, isFirstTrack: Bool, isLastTrack: Bool
    ) -> AccurateRipChecksum {
        var accumulator = AccurateRipAccumulator(
            sampleCount: samples.count, isFirstTrack: isFirstTrack, isLastTrack: isLastTrack)
        accumulator.add(samples)
        return accumulator.checksum
    }
}
