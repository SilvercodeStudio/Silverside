import Foundation

/// Loudness as ITU-R BS.1770-4 and EBU R 128 measure it, and ReplayGain 2.0 from it: the
/// gain that brings a track or an album to the reference loudness, and its peak. Our own
/// code, with the K-weighting filter's constants from the standard.
public enum ReplayGain {
    /// ReplayGain 2.0's reference loudness, in LUFS.
    public static let referenceLoudness = -18.0

    /// What a track's analysis keeps for the album's gating: the K-weighted mean square of
    /// each 400 ms block (one every 100 ms), and the track's sample peak as a fraction of
    /// full scale.
    public struct Analysis: Equatable, Sendable {
        public var blockPowers: [Double]
        public var peak: Double

        /// The track's integrated loudness in LUFS, or nil for a track below the gate (silence).
        public var loudness: Double? { ReplayGain.integratedLoudness(of: blockPowers) }
    }

    /// A track's or an album's gain in dB, its peak as a fraction of full scale, and its loudness in LUFS.
    public struct Values: Codable, Equatable, Sendable {
        public var gain: Double
        public var peak: Double
        public var loudness: Double

        public init(loudness: Double, peak: Double) {
            self.loudness = loudness
            self.peak = peak
            gain = ReplayGain.referenceLoudness - loudness
        }

        /// "+5.00 dB", as the ReplayGain tags have it.
        public var gainText: String { String(format: "%+.2f dB", gain) }
        public var peakText: String { String(format: "%.6f", peak) }
        public var loudnessText: String { String(format: "%.2f LUFS", loudness) }
    }

    /// Analyzes 16-bit stereo samples (left in the low half, right in the high half).
    public static func analyze(_ samples: [UInt32], sampleRate: Double = 44100) -> Analysis {
        var meter = Meter(sampleRate: sampleRate, frames: samples.count)
        samples.withUnsafeBufferPointer { samples in
            for sample in samples {
                meter.add(
                    Double(Int16(truncatingIfNeeded: sample & 0xFFFF)) / 32768,
                    Double(Int16(truncatingIfNeeded: sample >> 16)) / 32768)
            }
        }
        return meter.analysis
    }

    /// Analyzes 16-bit audio, or the wider audio of an HDCD decode.
    public static func analyze(_ pcm: TrackPCM, sampleRate: Double = 44100) -> Analysis {
        switch pcm {
        case .cd(let samples):
            return analyze(samples, sampleRate: sampleRate)
        case .wide(let values):
            var meter = Meter(sampleRate: sampleRate, frames: values.count / 2)
            values.withUnsafeBufferPointer { values in
                for index in stride(from: 0, to: values.count - 1, by: 2) {
                    meter.add(Double(values[index]) / 2_147_483_648, Double(values[index + 1]) / 2_147_483_648)
                }
            }
            return meter.analysis
        }
    }

    /// Analyzes surround audio, as BS.1770 weighs its channels: the surround channels count
    /// 1.41 times (+1.5 dB), the low-frequency effects channel not at all, and its peak is
    /// the highest of every channel's.
    public static func analyze(_ audio: SurroundPCM, sampleRate: Double = 44100) -> Analysis {
        let channels = audio.channels
        // WAVE's bits, in channel order: back left and right, side left and right, back center.
        var weights = [Double]()
        var bit: UInt32 = 1
        while weights.count < channels, bit != 0 {
            if audio.channelMask & bit != 0 {
                weights.append(
                    bit == SurroundPCM.lfeBit ? 0 : [0x10, 0x20, 0x100, 0x200, 0x400].contains(bit) ? 1.41 : 1)
            }
            bit <<= 1
        }
        while weights.count < channels { weights.append(1) }
        let step = Int((sampleRate / 10).rounded())
        var filters = (0..<channels).map { _ in KWeighting(sampleRate: sampleRate) }
        var stepPowers = [Double]()
        stepPowers.reserveCapacity(audio.frameCount / step + 1)
        var peak = 0.0
        var sum = 0.0
        var inStep = 0
        audio.values.withUnsafeBufferPointer { values in
            for frame in 0..<audio.frameCount {
                for channel in 0..<channels {
                    let x = Double(values[frame * channels + channel]) / 2_147_483_648
                    peak = max(peak, abs(x))
                    guard weights[channel] > 0 else { continue }
                    let z = filters[channel].filter(x)
                    sum += weights[channel] * z * z
                }
                inStep += 1
                if inStep == step {
                    stepPowers.append(sum)
                    sum = 0
                    inStep = 0
                }
            }
        }
        return Analysis(blockPowers: blocks(of: stepPowers, step: step), peak: peak)
    }

    /// The 400 ms blocks of the 100 ms steps: four steps each, as the mean square over them.
    static func blocks(of stepPowers: [Double], step: Int) -> [Double] {
        guard stepPowers.count >= 4 else { return [] }
        return (0..<(stepPowers.count - 3)).map {
            (stepPowers[$0] + stepPowers[$0 + 1] + stepPowers[$0 + 2] + stepPowers[$0 + 3]) / Double(4 * step)
        }
    }

    /// The measurement as the samples go by: each 100 ms step's K-weighted power, and the peak.
    private struct Meter {
        let step: Int
        var stepPowers = [Double]()
        var peak = 0.0
        var left: KWeighting
        var right: KWeighting
        var sum = 0.0
        var inStep = 0

        init(sampleRate: Double, frames: Int) {
            step = Int((sampleRate / 10).rounded())
            stepPowers.reserveCapacity(frames / step + 1)
            left = KWeighting(sampleRate: sampleRate)
            right = KWeighting(sampleRate: sampleRate)
        }

        /// One frame, each channel as a fraction of full scale.
        @inline(__always) mutating func add(_ l: Double, _ r: Double) {
            peak = max(peak, abs(l), abs(r))
            let zl = left.filter(l)
            let zr = right.filter(r)
            sum += zl * zl + zr * zr
            inStep += 1
            if inStep == step {
                stepPowers.append(sum)
                sum = 0
                inStep = 0
            }
        }

        var analysis: Analysis {
            Analysis(blockPowers: ReplayGain.blocks(of: stepPowers, step: step), peak: peak)
        }
    }

    /// The integrated loudness of blocks, gated as BS.1770 says: blocks under -70 LUFS are
    /// left out, then blocks more than 10 LU under the mean of the rest. Nil if no block
    /// passes the absolute gate. An album's loudness is this over every track's blocks.
    public static func integratedLoudness(of blockPowers: [Double]) -> Double? {
        func loudness(_ power: Double) -> Double { -0.691 + 10 * log10(power) }
        let loud = blockPowers.filter { $0 > 0 && loudness($0) > -70 }
        guard !loud.isEmpty else { return nil }
        let relative = loudness(loud.reduce(0, +) / Double(loud.count)) - 10
        let gated = loud.filter { loudness($0) > relative }
        guard !gated.isEmpty else { return nil }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }

    /// The album's values from its tracks' analyses: one gating over every block, and the highest peak.
    public static func album(of analyses: [Analysis]) -> Values? {
        guard let loudness = integratedLoudness(of: analyses.flatMap(\.blockPowers)) else { return nil }
        return Values(loudness: loudness, peak: analyses.map(\.peak).max() ?? 0)
    }

    /// What an album's gating needs from a disc, small enough to keep in its report: how many
    /// blocks fall in each 0.1 LU step of loudness from -70 LUFS, and the highest sample peak.
    /// The album of a multi-disc release is gated over every disc's blocks, so each disc keeps
    /// this, and the album's gain is found without the audio of the other discs. A step's
    /// blocks count at its middle loudness, as libebur128's histogram mode does: for music,
    /// whose blocks spread over many steps, the result is within 0.01 dB of a gating over
    /// the blocks themselves, and never more than half a step (0.05 dB) from it.
    public struct Histogram: Codable, Equatable, Sendable {
        /// The step of the first count: step i holds blocks from -70 + i / 10 LUFS.
        public var first: Int
        public var counts: [Int]
        public var peak: Double

        static let stepsPerLU = 10.0

        /// The blocks of the analyses above the absolute gate, and their highest peak.
        public init(_ analyses: [Analysis]) {
            var counts = [Int: Int]()
            for power in analyses.lazy.flatMap(\.blockPowers) where power > 0 {
                let loudness = -0.691 + 10 * log10(power)
                guard loudness > -70 else { continue }
                counts[Int(((loudness + 70) * Self.stepsPerLU).rounded(.down)), default: 0] += 1
            }
            first = counts.keys.min() ?? 0
            let last = counts.keys.max() ?? -1
            self.counts = last < first ? [] : (first...last).map { counts[$0] ?? 0 }
            peak = analyses.map(\.peak).max() ?? 0
        }

        /// The integrated loudness of every block of the histograms, gated as BS.1770 says, or
        /// nil if no block is above the absolute gate.
        public static func loudness(of histograms: [Histogram]) -> Double? {
            func power(_ loudness: Double) -> Double { pow(10, (loudness + 0.691) / 10) }
            var steps = [(loudness: Double, count: Int)]()
            for histogram in histograms {
                for (offset, count) in histogram.counts.enumerated() where count > 0 {
                    steps.append((-70 + (Double(histogram.first + offset) + 0.5) / stepsPerLU, count))
                }
            }
            let blocks = steps.reduce(0) { $0 + $1.count }
            guard blocks > 0 else { return nil }
            let mean = steps.reduce(0) { $0 + Double($1.count) * power($1.loudness) } / Double(blocks)
            let relative = -0.691 + 10 * log10(mean) - 10
            let gated = steps.filter { $0.loudness > relative }
            let gatedBlocks = gated.reduce(0) { $0 + $1.count }
            guard gatedBlocks > 0 else { return nil }
            return -0.691 + 10
                * log10(gated.reduce(0) { $0 + Double($1.count) * power($1.loudness) } / Double(gatedBlocks))
        }
    }

    /// An album's values over several discs: one gating over every disc's blocks, and the highest peak.
    public static func album(of histograms: [Histogram]) -> Values? {
        guard let loudness = Histogram.loudness(of: histograms) else { return nil }
        return Values(loudness: loudness, peak: histograms.map(\.peak).max() ?? 0)
    }

    /// The tags, as Vorbis comments: track and album gain and peak, and the reference loudness.
    public static func tags(track: Values?, album: Values?) -> [(key: String, value: String)] {
        var tags = [(key: String, value: String)]()
        if let track {
            tags += [("REPLAYGAIN_TRACK_GAIN", track.gainText), ("REPLAYGAIN_TRACK_PEAK", track.peakText)]
        }
        if let album {
            tags += [("REPLAYGAIN_ALBUM_GAIN", album.gainText), ("REPLAYGAIN_ALBUM_PEAK", album.peakText)]
        }
        if !tags.isEmpty {
            tags.append(("REPLAYGAIN_REFERENCE_LOUDNESS", String(format: "%.2f LUFS", referenceLoudness)))
        }
        return tags
    }
}

/// BS.1770's K-weighting: a high shelf (+4 dB above about 1.5 kHz, the head's effect) and a
/// high-pass at 38 Hz, two biquads in series. The constants are the standard's, given at
/// 48 kHz; the coefficients come from them for any sample rate, as libebur128 derives them.
struct KWeighting {
    private var shelf: Biquad
    private var highPass: Biquad

    init(sampleRate: Double) {
        do {
            let f0 = 1681.974450955533
            let gain = 3.999843853973347
            let q = 0.7071752369554196
            let k = tan(.pi * f0 / sampleRate)
            let vh = pow(10, gain / 20)
            let vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + k / q + k * k
            shelf = Biquad(
                b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        }
        do {
            let f0 = 38.13547087602444
            let q = 0.5003270373238773
            let k = tan(.pi * f0 / sampleRate)
            let a0 = 1 + k / q + k * k
            highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        }
    }

    @inline(__always) mutating func filter(_ x: Double) -> Double {
        highPass.filter(shelf.filter(x))
    }
}

/// A second-order filter, direct form II transposed.
struct Biquad {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var s1 = 0.0, s2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        (self.b0, self.b1, self.b2, self.a1, self.a2) = (b0, b1, b2, a1, a2)
    }

    @inline(__always) mutating func filter(_ x: Double) -> Double {
        let y = b0 * x + s1
        s1 = b1 * x - a1 * y + s2
        s2 = b2 * x - a2 * y
        return y
    }
}
