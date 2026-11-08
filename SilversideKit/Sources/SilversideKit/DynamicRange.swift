import Foundation

/// Dynamic range as the DR meter measures it (the "DR12" of the Dynamic Range Database): how
/// far the loudest peaks rise over the loudest parts' RMS, in dB. A master limited hard for
/// loudness has a low DR. Our own code, from Algorithmix's description of the measurement
/// ("Measuring DR", version 1.3, 2009): each channel in blocks of 132,480 samples (3 seconds
/// at 44.1 kHz), each block's RMS (times √2, so a full-scale sine has 0 dB) and peak; a
/// channel's DR is its second-highest block peak over the RMS of its loudest 20% of blocks;
/// a track's is the mean of its channels'. The value people compare is that rounded to a
/// whole number; an album's is the mean of its tracks' whole numbers, rounded.
public enum DynamicRange {
    /// A block's length in frames: 132,480 at 44.1 kHz, as the description has it.
    static func blockFrames(sampleRate: Double) -> Int { Int((132_480 * sampleRate / 44_100).rounded()) }

    /// One channel's blocks as the samples go by.
    struct Channel {
        var squares = [Double]()
        var peaks = [Double]()
        var frames = [Int]()
        private var sum = 0.0
        private var peak = 0.0

        @inline(__always) mutating func add(_ x: Double) {
            sum += x * x
            peak = max(peak, abs(x))
        }

        /// Ends the block of `count` frames. The last block of a track is shorter.
        mutating func endBlock(frames count: Int) {
            guard count > 0 else { return }
            squares.append(sum)
            peaks.append(peak)
            frames.append(count)
            sum = 0
            peak = 0
        }

        /// The channel's DR in dB, or nil for silence.
        var value: Double? {
            let rms = zip(squares, frames).map { (2 * $0 / Double($1)).squareRoot() }.sorted(by: >)
            let peaks = peaks.sorted(by: >)
            guard let first = peaks.first else { return nil }
            let peak = peaks.count > 1 ? peaks[1] : first
            // The loudest 20%, at least one block.
            let loudest = rms.prefix(max(1, Int((0.2 * Double(rms.count)).rounded(.up))))
            let power = loudest.reduce(0) { $0 + $1 * $1 } / Double(loudest.count)
            guard peak > 0, power > 0 else { return nil }
            return 20 * log10(peak / power.squareRoot())
        }
    }

    /// The blocks of every channel, counted together.
    struct Meter {
        let blockFrames: Int
        var channels: [Channel]
        private var inBlock = 0

        init(sampleRate: Double, channels: Int) {
            blockFrames = DynamicRange.blockFrames(sampleRate: sampleRate)
            self.channels = Array(repeating: Channel(), count: channels)
        }

        /// After each frame's channels are added.
        @inline(__always) mutating func endFrame() {
            inBlock += 1
            if inBlock == blockFrames {
                for index in channels.indices { channels[index].endBlock(frames: inBlock) }
                inBlock = 0
            }
        }

        /// The track's DR: the mean of its channels' that are not silent. Nil for silence.
        mutating func finish() -> Double? {
            for index in channels.indices { channels[index].endBlock(frames: inBlock) }
            inBlock = 0
            let values = channels.compactMap(\.value)
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
    }

    /// The whole number that people compare: "DR12".
    public static func official(_ value: Double) -> Int { Int(value.rounded()) }

    /// An album's DR: the mean of its tracks' whole numbers, rounded. Nil with no track measured.
    public static func album(of trackValues: [Double]) -> Int? {
        guard !trackValues.isEmpty else { return nil }
        return Int((Double(trackValues.map(official).reduce(0, +)) / Double(trackValues.count)).rounded())
    }

    /// "DR12".
    public static func text(_ value: Int) -> String { "DR\(value)" }
}

/// Loudness range (LRA) as EBU Tech 3342 measures it: how far the loudness moves between the
/// quiet and the loud parts, in LU, from the BS.1770 loudness of 3-second windows every 100 ms.
/// Windows under -70 LUFS are left out, then windows more than 20 LU under the mean of the
/// rest; the range is from the 10th percentile of what is left to the 95th. Unlike DR, it
/// shows the swings of a piece more than the limiting of its peaks.
public enum LoudnessRange {
    /// Short-term windows: 30 steps of 100 ms.
    static let windowSteps = 30

    /// The mean square of each 3-second window, one every step, from the steps' sums of squares.
    static func shortTermPowers(of stepPowers: [Double], step: Int) -> [Double] {
        guard stepPowers.count >= windowSteps else { return [] }
        var powers = [Double]()
        powers.reserveCapacity(stepPowers.count - windowSteps + 1)
        var sum = stepPowers.prefix(windowSteps).reduce(0, +)
        let scale = 1 / Double(windowSteps * step)
        powers.append(sum * scale)
        for index in windowSteps..<stepPowers.count {
            sum += stepPowers[index] - stepPowers[index - windowSteps]
            powers.append(max(0, sum) * scale)
        }
        return powers
    }

    static func loudness(_ power: Double) -> Double { -0.691 + 10 * log10(power) }
    static func power(_ loudness: Double) -> Double { pow(10, (loudness + 0.691) / 10) }

    /// The loudness range of short-term windows in LU, or nil when none is above the gates.
    public static func range(of shortTermPowers: [Double]) -> Double? {
        let loud = shortTermPowers.filter { $0 > 0 }.map(loudness).filter { $0 >= -70 }
        guard !loud.isEmpty else { return nil }
        let gate = loudness(loud.reduce(0) { $0 + power($1) } / Double(loud.count)) - 20
        let kept = loud.filter { $0 >= gate }.sorted()
        guard !kept.isEmpty else { return nil }
        return kept[percentile(0.95, of: kept.count)] - kept[percentile(0.10, of: kept.count)]
    }

    /// The index of a percentile among `count` sorted values, as Tech 3342's reference code takes it.
    static func percentile(_ fraction: Double, of count: Int) -> Int {
        Int((Double(count - 1) * fraction).rounded())
    }

    /// What a multi-disc album's range needs from a disc, small enough to keep in its report:
    /// how many short-term windows fall in each 0.1 LU step from -70 LUFS. A step's windows
    /// count at its middle, so the range is within 0.1 LU of one over the windows themselves.
    public struct Histogram: Codable, Equatable, Sendable {
        /// The step of the first count: step i holds windows from -70 + i / 10 LUFS.
        public var first: Int
        public var counts: [Int]

        static let stepsPerLU = 10.0

        public init(_ shortTermPowers: [Double]) {
            var counts = [Int: Int]()
            for power in shortTermPowers where power > 0 {
                let loudness = LoudnessRange.loudness(power)
                guard loudness >= -70 else { continue }
                counts[Int(((loudness + 70) * Self.stepsPerLU).rounded(.down)), default: 0] += 1
            }
            first = counts.keys.min() ?? 0
            let last = counts.keys.max() ?? -1
            self.counts = last < first ? [] : (first...last).map { counts[$0] ?? 0 }
        }

        /// The loudness range over every window of the histograms, or nil when none is above the gates.
        public static func range(of histograms: [Histogram]) -> Double? {
            var steps = [Double: Int]()
            for histogram in histograms {
                for (offset, count) in histogram.counts.enumerated() where count > 0 {
                    steps[-70 + (Double(histogram.first + offset) + 0.5) / stepsPerLU, default: 0] += count
                }
            }
            let windows = steps.values.reduce(0, +)
            guard windows > 0 else { return nil }
            let mean = steps.reduce(0) { $0 + Double($1.value) * power($1.key) } / Double(windows)
            let gate = loudness(mean) - 20
            let kept = steps.filter { $0.key >= gate }.sorted { $0.key < $1.key }
            let count = kept.reduce(0) { $0 + $1.value }
            guard count > 0 else { return nil }
            func value(at index: Int) -> Double {
                var seen = 0
                for (loudness, windows) in kept {
                    seen += windows
                    if index < seen { return loudness }
                }
                return kept.last!.key
            }
            return value(at: percentile(0.95, of: count)) - value(at: percentile(0.10, of: count))
        }
    }

    /// "8.4 LU".
    public static func text(_ value: Double) -> String { String(format: "%.1f LU", value) }
}
