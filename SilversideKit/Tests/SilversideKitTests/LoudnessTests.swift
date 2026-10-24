import Foundation
import Testing

@testable import SilversideKit

struct LoudnessTests {
    /// A stereo sine at 997 Hz, `level` dBFS (a full-scale sine is 0 dBFS), for `seconds`.
    func sine(level: Double, seconds: Double, frequency: Double = 997) -> [UInt32] {
        let amplitude = pow(10, level / 20) * 32767
        return (0..<Int(44100 * seconds)).map { i in
            let value = Int16((amplitude * sin(2 * .pi * frequency * Double(i) / 44100)).rounded())
            return UInt32(UInt16(bitPattern: value)) | UInt32(UInt16(bitPattern: value)) << 16
        }
    }

    /// EBU Tech 3341's first test: a stereo 997 Hz sine at -23 dBFS reads -23.0 LUFS, within 0.1.
    /// The -0.691 constant cancels the K-weighting's gain at 1 kHz, so a full-scale sine reads 0.
    @Test func measuresASineAsTheStandardSays() {
        let quiet = ReplayGain.analyze(sine(level: -23, seconds: 5))
        let loudness = try! #require(quiet.loudness)
        #expect(abs(loudness - -23) < 0.1)
        #expect(abs(quiet.peak - pow(10, -23 / 20)) < 0.001)
        let values = ReplayGain.Values(loudness: loudness, peak: quiet.peak)
        #expect(abs(values.gain - 5) < 0.1 && values.gainText.hasPrefix("+") && values.gainText.hasSuffix(" dB"))
        #expect(values.peakText == String(format: "%.6f", quiet.peak))
        let full = ReplayGain.analyze(sine(level: 0, seconds: 3))
        #expect(abs((full.loudness ?? -99) - 0) < 0.1 && full.peak > 0.9999)
    }

    /// Silence has no loudness, and quiet parts are gated out. EBU Tech 3341's third test:
    /// 10 s at -36 dBFS, 20 s at -23, 10 s at -36 reads -23.0 LUFS, within 0.1.
    @Test func gatesSilenceAndQuietParts() {
        #expect(ReplayGain.analyze([UInt32](repeating: 0, count: 44100)).loudness == nil)
        #expect(ReplayGain.analyze(sine(level: -23, seconds: 0.3)).loudness == nil)
        let gated = ReplayGain.analyze(
            sine(level: -36, seconds: 10) + sine(level: -23, seconds: 20) + sine(level: -36, seconds: 10))
        #expect(abs((gated.loudness ?? -99) - -23) < 0.1)
        // Not gated: a part 6 LU down is within the relative gate, so the mean lies between.
        let mixed = ReplayGain.analyze(sine(level: -23, seconds: 3) + sine(level: -29, seconds: 3))
        let expected = -0.691 + 10 * log10((pow(10, (-23 + 0.691) / 10) + pow(10, (-29 + 0.691) / 10)) / 2)
        #expect(abs((mixed.loudness ?? -99) - expected) < 0.15)
    }

    /// The album's loudness is one gating over every track's blocks, and its peak the highest.
    @Test func measuresAnAlbumOverItsTracks() throws {
        let tracks = [
            ReplayGain.analyze(sine(level: -23, seconds: 3)), ReplayGain.analyze(sine(level: -29, seconds: 3)),
        ]
        let album = try #require(ReplayGain.album(of: tracks))
        let expected = -0.691 + 10 * log10((pow(10, (-23 + 0.691) / 10) + pow(10, (-29 + 0.691) / 10)) / 2)
        #expect(abs(album.loudness - expected) < 0.15 && abs(album.peak - pow(10, -23 / 20)) < 0.001)
        let tags = ReplayGain.tags(track: ReplayGain.Values(loudness: -23, peak: 0.5), album: album)
        #expect(
            tags.map(\.key) == [
                "REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_TRACK_PEAK", "REPLAYGAIN_ALBUM_GAIN", "REPLAYGAIN_ALBUM_PEAK",
                "REPLAYGAIN_REFERENCE_LOUDNESS",
            ])
        #expect(tags[0].value == "+5.00 dB" && tags[1].value == "0.500000" && tags[4].value == "-18.00 LUFS")
        #expect(ReplayGain.tags(track: nil, album: nil).isEmpty)
    }
}
