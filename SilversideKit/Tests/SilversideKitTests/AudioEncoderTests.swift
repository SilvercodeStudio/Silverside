import Foundation
import Testing

@testable import SilversideKit

struct AudioEncoderTests {
    /// Ten seconds of music-like audio: a few tones and a little noise, so encoders work as on real tracks.
    static let samples: [UInt32] = {
        var generator = SplitMix64(state: 9)
        return (0..<441_000).map { index in
            let t = Double(index) / 44_100
            let tone = 9000 * sin(2 * .pi * 220 * t) + 4000 * sin(2 * .pi * 554 * t)
            func channel(_ phase: Double) -> UInt32 {
                let noise = Double(Int(generator.next() % 400)) - 200
                return UInt32(UInt16(bitPattern: Int16(tone * cos(phase) + noise)))
            }
            return channel(0) | channel(0.3) << 16
        }
    }()

    func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())-\(name)")
    }

    @Test(arguments: [AudioFormat.flac, .alac, .aiff])
    func losslessFormatsGiveBackEverySample(format: AudioFormat) throws {
        let url = temporaryFile("track.\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioEncoder.encode(Self.samples, format: format, to: url)
        #expect(try AudioEncoder.decode(url) == Self.samples)
    }

    @Test func aacIsSmallAndAboutAsLong() throws {
        let url = temporaryFile("track.m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioEncoder.encode(Self.samples, format: .aac, to: url, aac: AACOptions(mode: .cbr, bitRate: 256))
        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        // 10 s at 256 kbit/s is about 320 KB.
        #expect((250_000...420_000).contains(size))
        #expect(abs(try AudioEncoder.decode(url).count - Self.samples.count) < 4096)
    }

    /// Each mode works, and the bit rate (or the VBR quality) changes the size.
    @Test(arguments: AACOptions.Mode.allCases)
    func aacTakesEachMode(mode: AACOptions.Mode) throws {
        func size(_ options: AACOptions) throws -> Int {
            let url = temporaryFile("track.m4a")
            defer { try? FileManager.default.removeItem(at: url) }
            try AudioEncoder.encode(Self.samples, format: .aac, to: url, aac: options)
            return try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        }
        if mode == .vbr {
            #expect(try size(AACOptions(mode: .vbr, vbrQuality: 20)) < size(AACOptions(mode: .vbr, vbrQuality: 127)))
        } else {
            #expect(try size(AACOptions(mode: mode, bitRate: 96)) < size(AACOptions(mode: mode, bitRate: 256)))
        }
    }

    @Test func mp3OptionsBecomeLameArguments() {
        #expect(MP3Options().lameArguments == ["-V", "0"])
        #expect(MP3Options(mode: .cbr, bitRate: 192).lameArguments == ["-b", "192", "--cbr"])
        #expect(
            MP3Options(mode: .abr, bitRate: 160, extraArguments: ["-q", "0"]).lameArguments == [
                "--abr", "160", "-q", "0",
            ])
    }

    @Test func refusesFormatsThatHaveTheirOwnWriter() {
        #expect(throws: AudioEncoderError.notThroughAudioToolbox(.mp3)) {
            try AudioEncoder.encode([], format: .mp3, to: temporaryFile("x.mp3"))
        }
    }
}
