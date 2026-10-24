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
        let step = Int((sampleRate / 10).rounded())
        var stepPowers = [Double]()
        stepPowers.reserveCapacity(samples.count / step + 1)
        var peak = 0
        var left = KWeighting(sampleRate: sampleRate)
        var right = KWeighting(sampleRate: sampleRate)
        var sum = 0.0
        var inStep = 0
        samples.withUnsafeBufferPointer { samples in
            for sample in samples {
                let l = Int(Int16(truncatingIfNeeded: sample & 0xFFFF))
                let r = Int(Int16(truncatingIfNeeded: sample >> 16))
                peak = max(peak, abs(l), abs(r))
                let zl = left.filter(Double(l) / 32768)
                let zr = right.filter(Double(r) / 32768)
                sum += zl * zl + zr * zr
                inStep += 1
                if inStep == step {
                    stepPowers.append(sum)
                    sum = 0
                    inStep = 0
                }
            }
        }
        // A block is four steps (400 ms); its power is the mean square over them.
        var blocks = [Double]()
        if stepPowers.count >= 4 {
            blocks.reserveCapacity(stepPowers.count - 3)
            for i in 0..<(stepPowers.count - 3) {
                blocks.append(
                    (stepPowers[i] + stepPowers[i + 1] + stepPowers[i + 2] + stepPowers[i + 3]) / Double(4 * step))
            }
        }
        return Analysis(blockPowers: blocks, peak: Double(peak) / 32768)
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
