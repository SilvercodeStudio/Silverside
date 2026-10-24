import CHDCD
import Foundation

/// The HDCD codes in a track. HDCD (High Definition Compatible Digital) hides control codes
/// in the lowest bit of some samples. A player without a decoder plays the 16-bit audio as
/// it is; with a decoder, the codes can ask for two changes that mastering prepared:
/// **peak extend** expands the loudest peaks, which the master compressed by up to 9 dB,
/// and a **gain adjustment** lowers the level by up to 7.5 dB (the master raised quiet
/// passages by as much). Many discs with the logo have codes that ask for neither, and then
/// a decoder gives the same audio. The codes can also choose a filter in a hardware
/// decoder's converter (the transient filter), which a software decoder ignores.
///
/// FFmpeg's decoder finds the codes (`Vendor/HDCD`), so the values are the ones that
/// `ffmpeg -af hdcd` prints.
public struct HDCDCodes: Codable, Equatable, Sendable {
    public enum PeakExtend: String, Codable, Sendable {
        case never
        /// In some of the codes.
        case sometimes
        /// In every code.
        case always
    }

    /// Valid codes in the track.
    public var packets: Int
    public var peakExtend: PeakExtend
    /// The largest gain adjustment the codes ask for, in dB: 0 down to -7.5.
    public var maxGainAdjustment: Double
    public var transientFilter: Bool
    /// Codes that looked damaged.
    public var errors: Int

    public init(
        packets: Int, peakExtend: PeakExtend = .never, maxGainAdjustment: Double = 0, transientFilter: Bool = false,
        errors: Int = 0
    ) {
        self.packets = packets
        self.peakExtend = peakExtend
        self.maxGainAdjustment = maxGainAdjustment
        self.transientFilter = transientFilter
        self.errors = errors
    }

    /// True if a decoder would change the audio: peak extend or a gain adjustment.
    public var changesAudio: Bool { peakExtend != .never || maxGainAdjustment < 0 }

    /// What the codes ask for, for people: "peak extend, gain down to -3.5 dB", or "nothing".
    public var featuresText: String {
        var parts = [String]()
        switch peakExtend {
        case .never: break
        case .sometimes: parts.append("peak extend in places")
        case .always: parts.append("peak extend")
        }
        if maxGainAdjustment < 0 { parts.append(String(format: "gain down to %.1f dB", maxGainAdjustment)) }
        return parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
    }

    /// Finds the codes in 16-bit stereo samples (left in the low half). Nil if the track has none.
    public static func scan(_ samples: [UInt32], sampleRate: Int = 44100) -> HDCDCodes? {
        guard let decoder = hdcd_decoder_new(Int32(sampleRate)) else { return nil }
        defer { hdcd_decoder_free(decoder) }
        // Blocks of 4096 frames, as FFmpeg decodes a FLAC file: the decoder decides at the
        // end of each block whether both channels have codes.
        let block = 4096
        var buffer = [Int32](repeating: 0, count: block * 2)
        samples.withUnsafeBufferPointer { samples in
            var start = 0
            while start < samples.count {
                let count = min(block, samples.count - start)
                for index in 0..<count {
                    let sample = samples[start + index]
                    buffer[2 * index] = Int32(Int16(truncatingIfNeeded: sample))
                    buffer[2 * index + 1] = Int32(Int16(truncatingIfNeeded: sample >> 16))
                }
                hdcd_decoder_process(decoder, &buffer, Int32(count))
                start += count
            }
        }
        let summary = hdcd_decoder_summary(decoder)
        guard summary.detected != 0 else { return nil }
        let peakExtend: PeakExtend =
            switch summary.peak_extend {
            case 1: .sometimes
            case 2: .always
            default: .never
            }
        return HDCDCodes(
            packets: Int(summary.total_packets), peakExtend: peakExtend,
            maxGainAdjustment: Double(summary.max_gain_adjustment), transientFilter: summary.uses_transient_filter != 0,
            errors: Int(summary.errors))
    }

    /// Finds the codes in an audio file that AudioToolbox reads: WAV, AIFF, FLAC, or ALAC.
    /// A lossy file has none left.
    public static func scan(fileAt url: URL) throws -> HDCDCodes? {
        try scan(AudioEncoder.decode(url))
    }
}

/// What the HDCD codes of a rip's tracks ask for.
public enum HDCDStatus: String, Codable, Sendable {
    /// No track has HDCD codes.
    case noCodes
    /// Codes, but none asks for peak extend or a gain adjustment: a decoder gives the same audio.
    case codesOnly
    /// The codes of some track ask for peak extend or a gain adjustment.
    case featuresUsed

    public init(_ tracks: [RipReport.Track]) {
        let codes = tracks.compactMap(\.hdcd)
        self = codes.isEmpty ? .noCodes : codes.contains(where: \.changesAudio) ? .featuresUsed : .codesOnly
    }
}

extension HDCDStatus {
    /// What the HDCD codes of these tracks mean, for people. Nil if none has codes.
    public static func text(for tracks: [RipReport.Track]) -> String? {
        let coded = tracks.filter { $0.hdcd != nil }
        guard !coded.isEmpty else { return nil }
        let which =
            coded.count == tracks.count
            ? "every track has" : "\(coded.count) of \(tracks.count) tracks \(coded.count == 1 ? "has" : "have")"
        let features = coded.filter(\.hdcd!.changesAudio).map { "track \($0.number): \($0.hdcd!.featuresText)" }
        if features.isEmpty {
            return "HDCD: \(which) HDCD codes, but they ask for no peak extend or gain adjustment,"
                + " so an HDCD decoder would play the same audio."
        }
        return "HDCD: \(which) HDCD codes, and an HDCD decoder would change the audio ("
            + features.joined(separator: "; ") + "). The files hold the audio as it is on the disc."
    }
}

extension RipReport {
    /// What the HDCD codes mean for this rip, for people. Nil without codes, and in older reports.
    public var hdcdText: String? { hdcd == nil ? nil : HDCDStatus.text(for: tracks) }
}
