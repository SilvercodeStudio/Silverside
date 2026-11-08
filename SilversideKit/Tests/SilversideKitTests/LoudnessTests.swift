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

    /// Music whose level moves slowly over `seconds`, from `low` to `high` dBFS and back:
    /// its blocks spread over many steps of loudness, as a disc's do.
    func swell(low: Double, high: Double, seconds: Double) -> [UInt32] {
        let count = Int(44100 * seconds)
        return (0..<count).map { i in
            let level = low + (high - low) * sin(.pi * Double(i) / Double(count))
            let amplitude = pow(10, level / 20) * 32767
            let value = Int16((amplitude * sin(2 * .pi * 997 * Double(i) / 44100)).rounded())
            return UInt32(UInt16(bitPattern: value)) | UInt32(UInt16(bitPattern: value)) << 16
        }
    }

    /// A disc keeps a histogram of its blocks, so the album of several discs is gated without
    /// their audio, including a quiet part that the relative gate leaves out. For music, it
    /// is within 0.01 dB of a gating over the blocks themselves; at worst (every block at one
    /// loudness, as in a steady sine) within 0.05 dB, half a step.
    @Test func gatesAnAlbumOfSeveralDiscsFromTheirHistograms() throws {
        let one = [
            ReplayGain.analyze(swell(low: -30, high: -20, seconds: 20)),
            ReplayGain.analyze(swell(low: -45, high: -40, seconds: 5)),
        ]
        let two = [ReplayGain.analyze(swell(low: -24, high: -14, seconds: 15))]
        let exact = try #require(ReplayGain.album(of: one + two))
        let fromHistograms = try #require(ReplayGain.album(of: [ReplayGain.Histogram(one), ReplayGain.Histogram(two)]))
        #expect(abs(fromHistograms.loudness - exact.loudness) < 0.01 && fromHistograms.peak == exact.peak)
        // One disc's histogram gives the disc's own loudness.
        let alone = try #require(ReplayGain.album(of: [ReplayGain.Histogram(two)]))
        #expect(abs(alone.loudness - (ReplayGain.album(of: two)?.loudness ?? 0)) < 0.01)
        let steady = [ReplayGain.analyze(sine(level: -23, seconds: 4))]
        let steadyLoudness = try #require(ReplayGain.album(of: [ReplayGain.Histogram(steady)])?.loudness)
        #expect(abs(steadyLoudness - (steady[0].loudness ?? 0)) <= 0.05)
        // Silence gives an empty histogram and no loudness; the histogram survives JSON.
        let silent = ReplayGain.Histogram([ReplayGain.analyze([UInt32](repeating: 0, count: 44100))])
        #expect(silent.counts.isEmpty && ReplayGain.album(of: [silent]) == nil)
        let histogram = ReplayGain.Histogram(one)
        let decoded = try JSONDecoder().decode(
            ReplayGain.Histogram.self, from: JSONEncoder().encode(histogram))
        #expect(decoded == histogram && histogram.counts.count < 400)
    }
}

struct DynamicRangeTests {
    let block = DynamicRange.blockFrames(sampleRate: 44100)

    /// A stereo 997 Hz sine at `level` dBFS for `frames`.
    func sine(level: Double, frames: Int) -> [UInt32] {
        let amplitude = pow(10, level / 20) * 32767
        return (0..<frames).map { i in
            let value = Int16((amplitude * sin(2 * .pi * 997 * Double(i) / 44100)).rounded())
            return UInt32(UInt16(bitPattern: value)) | UInt32(UInt16(bitPattern: value)) << 16
        }
    }

    /// A full-scale sample in both channels.
    let spike = UInt32(0x7FFF) | UInt32(0x7FFF) << 16

    /// The DR is the second-highest block peak over the RMS of the loudest 20% of blocks: of
    /// 15 blocks, 12 at -20 dBFS and 3 at -10, the 3 decide the RMS (a sine's RMS counts
    /// √2 higher, so it equals its peak). One full-scale spike is not enough: the second
    /// peak is the loud blocks', so the DR is 0. A spike in two blocks gives 10.
    @Test func takesTheSecondPeakOverTheLoudestBlocks() throws {
        var audio = (0..<15).flatMap { sine(level: $0 < 3 ? -10 : -20, frames: block) }
        audio[5 * block + 100] = spike
        let one = try #require(ReplayGain.analyze(audio).dynamicRange)
        #expect(abs(one - 0) < 0.05)
        audio[9 * block + 100] = spike
        let two = try #require(ReplayGain.analyze(audio).dynamicRange)
        #expect(abs(two - 10) < 0.05 && DynamicRange.official(two) == 10)
        #expect(ReplayGain.analyze([UInt32](repeating: 0, count: 44100)).dynamicRange == nil)
    }

    /// An album's DR is the mean of its tracks' whole numbers, rounded.
    @Test func roundsTheTracksBeforeTheAlbum() {
        #expect(DynamicRange.album(of: [10.4, 11.6]) == 11)
        #expect(DynamicRange.album(of: [10.4, 10.4, 12.5]) == 11)
        #expect(DynamicRange.album(of: []) == nil)
        #expect(DynamicRange.text(12) == "DR12")
    }

    /// EBU Tech 3342's first three test signals: a 1 kHz sine at one level for 20 s, then at
    /// another for 20 s, has the range between them, within 1 LU; a disc's histogram gives the
    /// same within 0.1.
    @Test func measuresTheLoudnessRangeAsTheStandardSays() throws {
        func twoParts(_ first: Double, _ second: Double) -> [UInt32] {
            LoudnessTests().sine(level: first, seconds: 20, frequency: 1000)
                + LoudnessTests().sine(level: second, seconds: 20, frequency: 1000)
        }
        for (first, second, expected) in [(-20.0, -30.0, 10.0), (-20, -15, 5), (-40, -20, 20)] {
            let analysis = ReplayGain.analyze(twoParts(first, second))
            let range = try #require(analysis.loudnessRange)
            #expect(abs(range - expected) < 1)
            let fromHistogram = try #require(
                LoudnessRange.Histogram.range(of: [LoudnessRange.Histogram(analysis.shortTermPowers)]))
            #expect(abs(fromHistogram - range) <= 0.1)
        }
        #expect(ReplayGain.analyze(LoudnessTests().sine(level: -20, seconds: 2)).loudnessRange == nil)
    }

    /// A disc's record: each track's values, the disc's, and the tags, the ranges only beside ReplayGain.
    @Test func recordsAndTagsTheDisc() throws {
        let loud = ReplayGain.analyze(LoudnessTests().sine(level: -10, seconds: 5))
        let quiet = ReplayGain.analyze(LoudnessTests().sine(level: -30, seconds: 5))
        let record = RipReport.Encoding.DynamicsRecord([(1, loud), (2, quiet)])
        #expect(record.tracks.map(\.track) == [1, 2] && record.dynamicRange == 0)
        #expect(abs((record.loudnessRange ?? 0) - 20) < 1)
        #expect(
            record.tags(forTrack: 1, ranges: true).map(\.key) == [
                "DYNAMIC RANGE", "ALBUM DYNAMIC RANGE", "REPLAYGAIN_TRACK_RANGE", "REPLAYGAIN_ALBUM_RANGE",
            ])
        #expect(record.tags(forTrack: 1, ranges: false).map(\.value) == ["0", "0"])
        var whole = record
        whole.release = .init(dynamicRange: 8, loudnessRange: 12.345, discs: 2)
        #expect(whole.tags(forTrack: 2, ranges: true).last?.value == "12.35 dB")
        #expect(whole.tags(forTrack: 2, ranges: true)[1].value == "0")
    }
}
