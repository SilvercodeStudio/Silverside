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
        let decoder = newDecoder(sampleRate)
        defer { hdcd_decoder_free(decoder) }
        run(decoder, over: samples) { _, _ in }
        return codes(found: hdcd_decoder_summary(decoder))
    }

    /// Frames of the audio before a track that settle the decoder: 5 seconds, longer than
    /// its 2-second code timer, and about 100 codes in the masters seen so far.
    static let warmUpFrames = 5 * 44100

    /// Decodes the track as an HDCD decoder plays it: audio of `bits` bits (`TrackPCM.wide`),
    /// 20 for FLAC and Apple Lossless, 24 otherwise (`AudioFormat.wideBits`). The decoder
    /// leaves room for the peaks that peak extend restores, so audio that the codes do not
    /// change comes out as it went in, 6.02 dB lower; audio without codes too.
    ///
    /// `previous` is the audio just before the track on the disc. A decoder starts with no
    /// code, so until the track's first code (often 50 ms in) it would not extend peaks or
    /// apply a gain. The end of `previous` sets the decoder as a player that plays the disc
    /// straight through has it, so gapless audio has no change at the track's start.
    public static func decode(
        _ samples: [UInt32], bits: Int = 24, previous: ArraySlice<UInt32>? = nil, sampleRate: Int = 44100
    ) -> [Int32] {
        let decoder = newDecoder(sampleRate)
        defer { hdcd_decoder_free(decoder) }
        let warmUp = previous.map { Array($0.suffix(warmUpFrames)) } ?? []
        var decoded = [Int32]()
        decoded.reserveCapacity(samples.count * 2)
        // The decoder's 32-bit values, cut to `bits` (truncated, as Apple's encoders cut them).
        let mask = ~Int32((1 << (32 - bits)) - 1)
        // The warm-up's values are left out.
        var skip = 2 * warmUp.count
        run(decoder, over: warmUp.isEmpty ? samples : warmUp + samples) { buffer, count in
            let start = min(skip, 2 * count)
            skip -= start
            for index in start..<(2 * count) { decoded.append(buffer[index] & mask) }
        }
        return decoded
    }

    /// A decoder. It fails only when its memory cannot be had, and then nothing it returned
    /// could be trusted: an empty decode would pass the lossless check and replace a track.
    private static func newDecoder(_ sampleRate: Int) -> OpaquePointer {
        guard let decoder = hdcd_decoder_new(Int32(sampleRate)) else {
            fatalError("No memory for the HDCD decoder.")
        }
        return decoder
    }

    /// Feeds the samples to the decoder in blocks of 4096 frames, as FFmpeg decodes a FLAC
    /// file: the decoder decides at the end of each block whether both channels have codes.
    /// `block` gets each block's decoded values.
    private static func run(
        _ decoder: OpaquePointer, over samples: [UInt32], block: (UnsafeMutableBufferPointer<Int32>, Int) -> Void
    ) {
        let size = 4096
        var buffer = [Int32](repeating: 0, count: size * 2)
        samples.withUnsafeBufferPointer { samples in
            buffer.withUnsafeMutableBufferPointer { buffer in
                var start = 0
                while start < samples.count {
                    let count = min(size, samples.count - start)
                    for index in 0..<count {
                        let sample = samples[start + index]
                        buffer[2 * index] = Int32(Int16(truncatingIfNeeded: sample))
                        buffer[2 * index + 1] = Int32(Int16(truncatingIfNeeded: sample >> 16))
                    }
                    hdcd_decoder_process(decoder, buffer.baseAddress, Int32(count))
                    block(buffer, count)
                    start += count
                }
            }
        }
    }

    private static func codes(found summary: hdcd_summary) -> HDCDCodes? {
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

/// What encoding does with a disc whose HDCD codes ask for peak extend or a gain adjustment.
/// A disc whose codes ask for nothing is encoded as it is: a decoder would give the same audio.
public enum HDCDChoice: String, Codable, CaseIterable, Sendable {
    /// The app asks when such a disc is about to be encoded; the command line keeps it as pressed.
    case ask
    /// Decode it into 20-bit files (24-bit for AIFF and WAV), tagged HDCD=decoded.
    case decode
    /// Encode the audio as it is on the disc, with the codes in it.
    case keep
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

    /// The tags for a disc's files: MEDIA=HDCD for a disc with HDCD codes, as MusicBrainz names
    /// the medium (and as cyanrip tags it), and HDCD=decoded for files that hold the decode.
    public static func tags(_ status: HDCDStatus?, decoded: Bool) -> [(key: String, value: String)] {
        let media: [(key: String, value: String)] =
            status == .codesOnly || status == .featuresUsed ? [("MEDIA", "HDCD")] : []
        return media + (decoded ? [("HDCD", "decoded")] : [])
    }
}

extension HDCDStatus {
    /// What the HDCD codes of these tracks mean, for people. Nil if none has codes.
    /// `decodedFormat`: the encoded files hold the HDCD decode, in that format.
    public static func text(for tracks: [RipReport.Track], decodedFormat: AudioFormat? = nil) -> String? {
        let coded = tracks.filter { $0.hdcd != nil }
        guard !coded.isEmpty else { return nil }
        let which =
            coded.count == tracks.count
            ? "every track has" : "\(coded.count) of \(tracks.count) tracks \(coded.count == 1 ? "has" : "have")"
        guard let features = features(of: tracks) else {
            return "HDCD: \(which) HDCD codes, but they ask for no peak extend or gain adjustment,"
                + " so an HDCD decoder would play the same audio. Any benefit of the HDCD mastering process is already in the audio."
        }
        return "HDCD: \(which) HDCD codes, and an HDCD decoder would change the audio (\(features))."
            + (decodedFormat.map {
                $0.isLossless
                    ? " The files hold the HDCD decode, at \($0.wideBits) bits." : " The files hold the HDCD decode."
            } ?? " The files hold the audio as it is on the disc.")
    }

    /// What the codes of these tracks ask for, for people: "peak extend in every track; gain down
    /// to -4.0 dB in tracks 1 and 9, -1.0 dB in track 8". Nil if they ask for nothing.
    public static func features(of tracks: [RipReport.Track]) -> String? {
        let coded = tracks.filter { $0.hdcd != nil }
        guard coded.contains(where: \.hdcd!.changesAudio) else { return nil }
        // "in every track", "in track 8", "in tracks 1 and 9", "in tracks 1, 4, and 9"
        func inTracks(_ numbers: [Int]) -> String {
            if numbers.count == tracks.count { return "in every track" }
            if numbers.count == 1 { return "in track \(numbers[0])" }
            if numbers.count == 2 { return "in tracks \(numbers[0]) and \(numbers[1])" }
            return "in tracks " + numbers.dropLast().map(String.init).joined(separator: ", ")
                + ", and \(numbers.last!)"
        }
        var features = [String]()
        let always = coded.filter { $0.hdcd!.peakExtend == .always }.map(\.number)
        let sometimes = coded.filter { $0.hdcd!.peakExtend == .sometimes }.map(\.number)
        if !always.isEmpty { features.append("peak extend \(inTracks(always))") }
        if !sometimes.isEmpty { features.append("peak extend in places \(inTracks(sometimes))") }
        // The gains, the largest first: "gain down to -4.0 dB in tracks 1 and 9, -1.0 dB in track 8".
        let gains = Dictionary(grouping: coded.filter { $0.hdcd!.maxGainAdjustment < 0 }) {
            $0.hdcd!.maxGainAdjustment
        }
        if !gains.isEmpty {
            features.append(
                "gain down to "
                    + gains.keys.sorted().map {
                        String(format: "%.1f dB ", $0) + inTracks(gains[$0]!.map(\.number))
                    }.joined(separator: ", "))
        }
        return features.joined(separator: "; ")
    }
}

extension RipReport {
    /// What the HDCD codes mean for this rip, for people. Nil without codes, and in older reports.
    public var hdcdText: String? {
        hdcd == nil
            ? nil : HDCDStatus.text(for: tracks, decodedFormat: encoding?.hdcdDecoded == true ? encoding?.format : nil)
    }
}
