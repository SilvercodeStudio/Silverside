import AudioToolbox
import Foundation
import Testing

@testable import SilversideKit

/// Each speaker's audio stays in that speaker, as another decoder (ffmpeg) reads the file:
/// Silverside's own read-back goes through the same Core Audio layouts as its writing, so it
/// cannot tell a channel that went to the wrong speaker.
struct SurroundLayoutTests {
    /// The layouts of ffmpeg's DTS decode, and others: 3.0, 2/1 (a back center), quad (back
    /// and side), 4.0 with a back center, 5.0, 5.1 (back and side; ffmpeg gives side, 0x60F),
    /// and DTS-ES 6.1.
    static let masks: [UInt32] = [0x7, 0x103, 0x33, 0x603, 0x107, 0x37, 0x607, 0x3F, 0x60F, 0x70F]

    /// A tone for each channel, its own frequency; the LFE channel's is low, as AAC keeps only
    /// the low frequencies there.
    static func tones(mask: UInt32, frames: Int = 44_100) -> (SurroundPCM, [Double]) {
        let bits = (0..<32).map { UInt32(1) << $0 }.filter { mask & $0 != 0 }
        var high = 440.0
        let hertz = bits.map { bit -> Double in
            if bit == SurroundPCM.lfeBit { return 60 }
            defer { high += 330 }
            return high
        }
        let channels = bits.count
        let values = (0..<(frames * channels)).map { index -> Int32 in
            let tone = sin(2 * .pi * hertz[index % channels] * Double(index / channels) / 44_100)
            return Int32((0.3 * tone * 524_287).rounded()) << 12
        }
        return (SurroundPCM(values: values, channels: channels, channelMask: mask, bits: 20), hertz)
    }

    /// The speaker bits of a mask, in WAVE's channel order.
    static func speakers(_ mask: UInt32) -> [UInt32] { (0..<32).map { UInt32(1) << $0 }.filter { mask & $0 != 0 } }

    /// The bit for a speaker in a layout that may name its surround pair as back or side ones:
    /// one pair is the same speakers either way.
    static func role(_ bit: UInt32, in mask: UInt32) -> UInt32 {
        let side: [UInt32: UInt32] = [0x200: 0x10, 0x400: 0x20]
        if let back = side[bit], mask & 0x30 == 0 { return back }
        return bit
    }

    static func ffmpegDecode(_ url: URL, ffmpeg: URL) throws -> SurroundPCM {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-v", "error", "-i", url.path, "-c:a", "pcm_s32le", "-f", "wav", "pipe:1"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try SurroundPCM(wave: bytes)
    }

    static func level(of hertz: Double, in audio: SurroundPCM, channel: Int) -> Double {
        var (real, imaginary) = (0.0, 0.0)
        for frame in 4000..<min(audio.frameCount, 40_000) {
            let value = Double(audio.values[audio.channels * frame + channel]) / 2_147_483_648
            let phase = 2 * .pi * hertz * Double(frame) / 44_100
            real += value * cos(phase)
            imaginary += value * sin(phase)
        }
        return hypot(real, imaginary)
    }

    /// Quad as each encoder holds it: AAC and FLAC have quad layouts of their own; Apple
    /// Lossless has none, so it is 5.0 with a silent center.
    @Test func placesQuad() throws {
        let aac = try #require(try SurroundLayout.of(mask: 0x603, format: .aac))
        #expect(aac.tag == kAudioChannelLayoutTag_Quadraphonic && aac.sources == [0, 1, 2, 3])
        let flac = try #require(try SurroundLayout.of(mask: 0x603, format: .flac))
        #expect(flac.tag == kAudioChannelLayoutTag_WAVE_4_0_B && flac.sources == [0, 1, 2, 3])
        let alac = try #require(try SurroundLayout.of(mask: 0x603, format: .alac))
        #expect(alac.tag == kAudioChannelLayoutTag_MPEG_5_0_D && alac.sources == [nil, 0, 1, 2, 3])
        #expect(try SurroundLayout.of(mask: 0x603, format: .aiff) == nil)
    }

    @Test(.enabled(if: FFmpeg.program() != nil), arguments: [AudioFormat.aac, .alac, .flac, .aiff])
    func keepsEachSpeakerInItsPlace(format: AudioFormat) throws {
        let ffmpeg = try #require(FFmpeg.program())
        for mask in Self.masks {
            let (audio, hertz) = Self.tones(mask: mask)
            let url = FileManager.default.temporaryDirectory.appending(
                path: "speakers-\(UUID()).\(format.fileExtension)")
            defer { try? FileManager.default.removeItem(at: url) }
            try AudioEncoder.encode(audio, format: format, to: url)
            let name = "\(format) 0x\(String(mask, radix: 16))"
            let decoded = try Self.ffmpegDecode(url, ffmpeg: ffmpeg)
            // A format with no layout of just these speakers gets silent channels too: quad in Apple Lossless is 5.0.
            #expect(decoded.channels >= audio.channels, "\(name)")
            let out = Self.speakers(decoded.channelMask).map { Self.role($0, in: decoded.channelMask) }
            var used = Set<Int>()
            for (index, bit) in Self.speakers(mask).enumerated() {
                let target = out.firstIndex(of: Self.role(bit, in: mask))
                #expect(target != nil, "\(name): no speaker 0x\(String(bit, radix: 16))")
                guard let target else { continue }
                used.insert(target)
                let levels = (0..<decoded.channels).map { Self.level(of: hertz[index], in: decoded, channel: $0) }
                #expect(
                    levels[target] == levels.max(),
                    """
                    \(name): speaker 0x\(String(bit, radix: 16)) is loudest in channel \
                    \(levels.firstIndex(of: levels.max()!)!) of 0x\(String(decoded.channelMask, radix: 16))
                    """)
            }
            for channel in 0..<decoded.channels where !used.contains(channel) {
                let peak =
                    stride(from: channel, to: decoded.values.count, by: decoded.channels).map {
                        abs(Int64(decoded.values[$0]))
                    }.max() ?? 0
                #expect(peak < 1 << 20, "\(name): channel \(channel) is not silent")
            }
            // Silverside's own read-back finds each speaker where it went: every value, in a lossless format.
            let own = try #require(try AudioEncoder.decodeSurround(url, as: mask), "\(name)")
            if format.isLossless { #expect(own.values == audio.values, "\(name)") }
            let all = try AudioEncoder.decodeSurround(url)
            #expect(
                Set(Self.speakers(all.channelMask).map { Self.role($0, in: all.channelMask) })
                    .isSuperset(of: Self.speakers(mask).map { Self.role($0, in: mask) }),
                "\(name): read back as 0x\(String(all.channelMask, radix: 16))")
        }
    }
}
