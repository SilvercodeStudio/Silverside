import CryptoKit
import Foundation
import Testing

@testable import SilversideKit

struct NativePCMTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-pcm-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Independent, full-precision samples for every speaker; odd lengths exercise the final chunk.
    func audio(rate: Double, channels: Int, bits: Int = 24) -> SurroundPCM {
        var generator = SplitMix64(state: 123)
        let values = (0..<(16_421 * channels)).map { _ in
            Int32(bitPattern: UInt32(truncatingIfNeeded: generator.next()) & (UInt32.max << (32 - bits)))
        }
        return SurroundPCM(
            values: values, channels: channels, channelMask: channels == 2 ? 3 : channels == 5 ? 0x37 : 0x3F,
            bits: bits, sampleRate: rate)
    }

    @Test(arguments: [AudioFormat.flac, .alac])
    func preservesRatesPrecisionAndSpeakers(format: AudioFormat) throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000] {
            for channels in [2, 6] {
                // DVD-Audio's six-channel ceiling is 96 kHz; 192 kHz is stereo.
                if channels == 6 && rate > 96_000 { continue }
                for bits in [16, 20, 24] {
                    let source = audio(rate: rate, channels: channels, bits: bits)
                    let url = dir.appendingPathComponent("track.\(format.fileExtension)")
                    try AudioEncoder.encode(source, format: format, to: url)
                    let decoded = try AudioEncoder.decodeSurround(url)
                    #expect((decoded == source), "\(format), \(rate) Hz, \(bits) bits, \(channels) channels")
                    let reader = try PCMFileReader(url)
                    #expect(reader.format == source.pcmFormat)
                    #expect(reader.frameCount == Int64(source.frameCount))
                    var values = [Int32]()
                    while let part = try reader.read(maxFrames: 997) { values += part }
                    #expect((values == source.values))
                }
            }
        }
    }

    @Test(.enabled(if: FFmpeg.program() != nil), arguments: [AudioFormat.flac, .alac])
    func independentDecoderGetsEverySpeakerAndSample(format: AudioFormat) throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ffmpeg = try #require(FFmpeg.program())
        for (rate, channels) in [(96_000.0, 5), (96_000.0, 6), (192_000.0, 2)] {
            let source = audio(rate: rate, channels: channels)
            let url = dir.appendingPathComponent("track.\(format.fileExtension)")
            try AudioEncoder.encode(source, format: format, to: url)
            let decoded = try SurroundLayoutTests.ffmpegDecode(url, ffmpeg: ffmpeg)
            #expect(decoded.sampleRate == rate)
            #expect(Self.roles(decoded.channelMask) == Self.roles(source.channelMask))
            #expect(
                (decoded.values == source.values),
                "\(rate) Hz, \(channels) channels, decoded \(decoded.frameCount) frames")
        }
    }

    static func roles(_ mask: UInt32) -> [UInt32] {
        SurroundLayoutTests.speakers(mask).map { SurroundLayoutTests.role($0, in: mask) }
    }

    @Test(.enabled(if: FFmpeg.program() != nil))
    func dvdFLACBlocksAreReadableByApple() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ffmpeg = try #require(FFmpeg.program())
        let source = audio(rate: 96_000, channels: 6)
        let original = dir.appendingPathComponent("original.flac")
        let small = dir.appendingPathComponent("small-blocks.flac")
        let compatible = dir.appendingPathComponent("compatible.flac")
        try AudioEncoder.encode(source, format: .flac, to: original)
        _ = try DVDProcess.run(
            ffmpeg, ["-v", "error", "-i", original.path, "-c:a", "flac", "-frame_size", "80", small.path], in: dir,
            stop: StopToken())
        var presentation = try DVDNavigation.presentations(
            ifo: DVDTests().navigation(), titleSet: 1, audioSectors: 200)[0]
        presentation.format = DVDAudioFormat(codec: "mlp", sampleRate: 96_000, bits: 24, channels: 6, layout: "5.1")
        _ = try DVDProcess.run(
            ffmpeg, ["-v", "error", "-i", small.path] + DVDExtraction.flacArguments(presentation) + [compatible.path],
            in: dir, stop: StopToken())
        let report = try AudioEncoder.transcodeLossless(
            compatible, format: .alac, to: dir.appendingPathComponent("track.m4a"))
        let expected = source.values.withUnsafeBytes { SHA256.hash(data: Data($0)) }
        #expect(report.pcmSHA256 == expected.map { String(format: "%02x", $0) }.joined())
        #expect(report.frames == Int64(source.frameCount))
    }

    @Test func streamsAndVerifiesLosslessConversion() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = audio(rate: 96_000, channels: 6)
        let flac = dir.appendingPathComponent("source.flac")
        let alac = dir.appendingPathComponent("converted.m4a")
        let back = dir.appendingPathComponent("converted.flac")
        try AudioEncoder.encode(source, format: .flac, to: flac)
        let report = try AudioEncoder.transcodeLossless(flac, format: .alac, to: alac)
        #expect(report.pcm == source.pcmFormat)
        #expect(report.frames == Int64(source.frameCount))
        let expected = source.values.withUnsafeBytes { SHA256.hash(data: Data($0)) }
        #expect(report.pcmSHA256 == expected.map { String(format: "%02x", $0) }.joined())
        #expect(try AudioEncoder.transcodeLossless(alac, format: .flac, to: back).pcmSHA256 == report.pcmSHA256)
        #expect(try AudioEncoder.decodeSurround(back) == source)
    }

    @Test func refusesInvalidPCMAndPreservesExistingFiles() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = audio(rate: 96_000, channels: 2)
        let url = dir.appendingPathComponent("source.flac")
        try AudioEncoder.encode(source, format: .flac, to: url)
        let original = try Data(contentsOf: url)
        for invalid in [
            PCMFormat(sampleRate: 0, channels: 2, channelMask: 3, bits: 24),
            PCMFormat(sampleRate: .nan, channels: 2, channelMask: 3, bits: 24),
            PCMFormat(sampleRate: 96_000, channels: 0, channelMask: 0, bits: 24),
            PCMFormat(sampleRate: 96_000, channels: 6, channelMask: 3, bits: 24),
            PCMFormat(sampleRate: 96_000, channels: 2, channelMask: 3, bits: 32),
        ] {
            #expect(throws: AudioEncoderError.self) {
                try AudioEncoder.encode(pcm: invalid, format: .flac, to: url) { nil }
            }
        }
        var dirty = source
        dirty.values[0] |= 1
        #expect(throws: AudioEncoderError.self) { try AudioEncoder.encode(dirty, format: .flac, to: url) }
        dirty = source
        dirty.values.removeLast()
        #expect(throws: AudioEncoderError.self) { try AudioEncoder.encode(dirty, format: .flac, to: url) }
        #expect(throws: AudioEncoderError.self) { try AudioEncoder.transcodeLossless(url, format: .flac, to: url) }
        let alias = dir.appendingPathComponent("alias.flac")
        try FileManager.default.linkItem(at: url, to: alias)
        #expect(throws: AudioEncoderError.self) { try AudioEncoder.transcodeLossless(url, format: .alac, to: alias) }
        #expect(try Data(contentsOf: url) == original)
        let stop = StopToken()
        stop.stop()
        let cancelled = dir.appendingPathComponent("cancelled.m4a")
        #expect(throws: CancellationError.self) {
            try AudioEncoder.transcodeLossless(url, format: .alac, to: cancelled, stop: stop)
        }
        #expect(!FileManager.default.fileExists(atPath: cancelled.path))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["alias.flac", "source.flac"])
    }

    @Test func loudnessUsesTheRecordedRate() {
        var source = audio(rate: 96_000, channels: 6)
        source.values = Array(repeating: source.values, count: 4).flatMap { $0 }
        let implicit = ReplayGain.analyze(source)
        let explicit = ReplayGain.analyze(source, sampleRate: 96_000)
        #expect(implicit == explicit)
    }

    @Test func failedVerificationRemovesOnlyItsTemporaryOutput() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        var quad = audio(rate: 96_000, channels: 2)
        quad.channels = 4
        quad.channelMask = 0x33
        quad.values.removeLast(quad.values.count % quad.channels)
        let source = dir.appendingPathComponent("quad.flac")
        let output = dir.appendingPathComponent("quad.m4a")
        try AudioEncoder.encode(quad, format: .flac, to: source)
        let original = try Data(contentsOf: source)
        // The existing ALAC writer represents quad as 5.0 with a silent center.
        // Strict native conversion must reject that format change, not publish it.
        #expect(throws: AudioEncoderError.self) {
            try AudioEncoder.transcodeLossless(source, format: .alac, to: output)
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["quad.flac"])
    }

    /// Opt-in integration check of an existing extraction; never opens a device or overwrites audio.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SILVERSIDE_TEST_PCM_SOURCE"] != nil))
    func convertsSavedExtraction() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SILVERSIDE_TEST_PCM_SOURCE"])
        #expect(!path.hasPrefix("/dev/"))
        guard !path.hasPrefix("/dev/") else { return }
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = try AudioEncoder.transcodeLossless(
            URL(fileURLWithPath: path), format: .alac,
            to: dir.appendingPathComponent("track.m4a"))
        #expect(report.pcm.sampleRate == 96_000)
        #expect(report.pcm.bits == 24)
        #expect(report.frames > 0)
        print(
            "Saved PCM conversion: \(report.frames) frames, \(report.pcm.channels) channels, SHA-256 \(report.pcmSHA256)"
        )
    }
}
