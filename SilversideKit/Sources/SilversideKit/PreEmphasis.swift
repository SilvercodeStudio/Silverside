import Foundation

/// De-emphasis: the filter that takes out a track's pre-emphasis, as a CD player does when
/// the track's control bits ask for it.
///
/// Pre-emphasis (IEC 60908) is a first-order treble boost with time constants of 50 µs and
/// 15 µs, so de-emphasis is the analog shelf H(s) = (1 + s·15 µs) / (1 + s·50 µs): flat at low
/// frequencies, -3 dB near 3.5 kHz, and -9.49 dB at 20 kHz, falling towards -10.46 dB. The
/// standard assumes an analog filter in the player and gives no digital one. A bilinear
/// transform of the shelf is 0.97 dB off at 20 kHz (it warps the curve near half the sample
/// rate), so this filter's pole and zero are fitted to the analog curve at 44.1 kHz instead:
/// within 0.08 dB from 20 Hz to 20 kHz.
public enum DeEmphasis {
    /// H(z) = gain · (1 - zero·z⁻¹) / (1 - pole·z⁻¹), with gain 1 at 0 Hz.
    static let pole = 0.62855453444264575
    static let zero = 0.19275336631887477
    static let gain = (1 - pole) / (1 - zero)

    /// Frames of the track before that settle the filter: its state then differs from a filter
    /// run over the whole disc by less than pole⁶⁴, about 10⁻¹³ of a sample.
    static let settlingFrames = 64

    /// The filter's gain at a frequency, in dB.
    public static func response(atFrequency frequency: Double, sampleRate: Double = 44_100) -> Double {
        let angle = 2 * Double.pi * frequency / sampleRate
        // |1 - root·e^(-iω)|
        func magnitude(_ root: Double) -> Double {
            let real = 1 - root * cos(angle)
            let imaginary = root * sin(angle)
            return (real * real + imaginary * imaginary).squareRoot()
        }
        return 20 * log10(gain * magnitude(zero) / magnitude(pole))
    }

    /// The analog de-emphasis curve's gain at a frequency, in dB: the reference for `response`.
    public static func analogResponse(atFrequency frequency: Double) -> Double {
        let omega = 2 * Double.pi * frequency
        return 10 * log10((1 + pow(omega * 15e-6, 2)) / (1 + pow(omega * 50e-6, 2)))
    }

    /// De-emphasizes a track: `bits`-bit values in the high bits of each `Int32`, interleaved
    /// (`TrackPCM.wide`), rounded to the nearest value (20 for FLAC and Apple Lossless, see
    /// `AudioFormat.wideBits`). The filter's gain is never above 1 and its impulse response is
    /// never negative, so no sample can exceed the loudest one going in: nothing clips.
    ///
    /// `previous` is the audio just before the track on the disc, when it is de-emphasized too:
    /// its last frames settle the filter, so that audio that runs from one track into the next
    /// has no step at the change. Without it, the filter starts at rest, as after a pause.
    public static func apply(_ pcm: TrackPCM, bits: Int, previous: TrackPCM? = nil) -> [Int32] {
        precondition((16...24).contains(bits), "De-emphasized audio has 16 to 24 bits")
        var filters = [Filter(), Filter()]
        if let previous {
            let frames = previous.frameCount
            for frame in max(0, frames - settlingFrames)..<frames {
                for channel in 0..<2 { _ = filters[channel].run(previous.value(frame: frame, channel: channel)) }
            }
        }
        // Values in 16-bit units become `bits`-bit values, then move to the top of the Int32.
        let scale = Double(1 << (bits - 16))
        let highest = Double((1 << (bits - 1)) - 1)
        let lowest = -Double(1 << (bits - 1))
        let shift = Int32(32 - bits)
        var output = [Int32](repeating: 0, count: pcm.frameCount * 2)
        for frame in 0..<pcm.frameCount {
            for channel in 0..<2 {
                let value = (filters[channel].run(pcm.value(frame: frame, channel: channel)) * scale).rounded()
                output[2 * frame + channel] = Int32(min(highest, max(lowest, value))) << shift
            }
        }
        return output
    }

    /// One channel's filter, with the input and output of the sample before.
    private struct Filter {
        var input = 0.0
        var output = 0.0

        mutating func run(_ value: Double) -> Double {
            output = gain * (value - zero * input) + pole * output
            input = value
            return output
        }
    }
}

extension TrackPCM {
    /// A channel's value at a frame, in 16-bit units (a 24-bit value is a fraction of one).
    fileprivate func value(frame: Int, channel: Int) -> Double {
        switch self {
        case .cd(let samples):
            Double(Int16(truncatingIfNeeded: channel == 0 ? samples[frame] : samples[frame] >> 16))
        case .wide(let values):
            Double(values[2 * frame + channel]) / 65_536
        }
    }
}

/// What encoding does with tracks whose control bits say pre-emphasis.
public enum PreEmphasisChoice: String, Codable, CaseIterable, Sendable {
    /// The app asks when such a disc is about to be encoded; the command line asks at a
    /// terminal, and de-emphasizes otherwise.
    case ask
    /// Take the pre-emphasis out, as a CD player does: 20-bit FLAC and Apple Lossless files
    /// (24-bit AIFF and WAV), tagged DE_EMPHASIZED=yes.
    case deEmphasize = "deemphasize"
    /// Encode the audio as it is on the disc, tagged PRE_EMPHASIS=yes.
    case keep
}

public enum PreEmphasis {
    /// The tags for a track's files: PRE_EMPHASIS=yes for audio as it is on the disc, which a
    /// player should de-emphasize; DE_EMPHASIZED=yes for audio that Silverside de-emphasized.
    /// No common tag exists; the CUE sheet's FLAGS PRE says the same for the disc as pressed.
    public static func tags(hasPreEmphasis: Bool, deEmphasized: Bool) -> [(key: String, value: String)] {
        if deEmphasized { return [("DE_EMPHASIZED", "yes")] }
        return hasPreEmphasis ? [("PRE_EMPHASIS", "yes")] : []
    }
}
