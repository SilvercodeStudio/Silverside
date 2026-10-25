import Foundation
import Testing

@testable import SilversideKit

struct HiddenTrackTests {
    /// A disc whose track 1 starts at LBA 100. Before it: random audio, or silence.
    func disc(silentGap: Bool) throws -> (reader: AudioReader, samples: [UInt32]) {
        let toc = try TOC(audioTrackStarts: [100, 560], leadOutLBA: 1000)
        var generator = SplitMix64(state: 4)
        var samples = (0..<(1000 * 588)).map { _ in UInt32.random(in: .min ... .max, using: &generator) }
        if silentGap { samples.replaceSubrange(0..<(100 * 588), with: repeatElement(0, count: 100 * 588)) }
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 667)
        return (AudioReader(drive: drive, toc: toc, readOffset: 667, canOverread: false), samples)
    }

    @Test func ripsAudioBeforeTrackOne() throws {
        let (reader, samples) = try disc(silentGap: false)
        let hidden = try #require(try HiddenTrackRip.rip(reader: reader, cacheFlushSectors: 50))
        #expect(hidden.readsAgree && hidden.reads == 2)
        #expect(hidden.samples[...] == samples[0..<(100 * 588)])
    }

    @Test func keepsNoSilentGap() throws {
        #expect(try HiddenTrackRip.rip(reader: disc(silentGap: true).reader) == nil)
        let (toc, samples) = try makeDisc(trackSectors: [100, 100])
        let reader = AudioReader(
            drive: SimulatedDrive(toc: toc, samples: samples), toc: toc, readOffset: 0, canOverread: false)
        #expect(try HiddenTrackRip.rip(reader: reader) == nil)
    }

    /// On a mixed-mode disc, the audio before the first audio track is a data track, not a hidden track.
    @Test func leavesADataTrackAlone() throws {
        let toc = try TOC(
            tracks: [.init(number: 1, startLBA: 0, kind: .data), .init(number: 2, startLBA: 3000)], leadOutLBA: 6000)
        let (_, samples) = try makeDisc(trackSectors: [6000])
        let drive = SimulatedDrive(toc: toc, samples: samples)
        let reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        #expect(try HiddenTrackRip.rip(reader: reader, cacheFlushSectors: 100) == nil)
        #expect(drive.discReads == 0)
    }

    @Test func putsTrackOnesIndexZeroInTheHiddenFile() {
        var sheet = CueSheet(tracks: [.init(number: 1, file: "01 One.flac", sectors: 460, pregapSectors: 100)])
        sheet.hiddenTrackFile = "00 Hidden Track.flac"
        #expect(
            sheet.text == """
                FILE "00 Hidden Track.flac" WAVE
                  TRACK 01 AUDIO
                    INDEX 00 00:00:00
                FILE "01 One.flac" WAVE
                    INDEX 01 00:00:00

                """)
    }

    @Test func encodesTheHiddenTrackAsTrackZero() throws {
        let (folder, library) = try EncodingTests().makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        var report = try RipReport.read(from: folder.appending(path: "disc.json"))
        report.hiddenTrack = .init(file: "Track 00.wav", sectors: 75, peak: 9000, readsAgree: true, reads: 2)
        try report.write(to: folder.appending(path: "disc.json"))
        try WAVFile.write(Array(AudioEncoderTests.samples.prefix(75 * 588)), to: folder.appending(path: "Track 00.wav"))
        var encoder = DiscEncoder(format: .flac)
        encoder.images = folder.deletingLastPathComponent().appending(path: "images")
        let (files, record) = try encoder.encodeWithRecord(try RippedDisc(folder: folder), into: library)
        #expect(files.map(\.lastPathComponent).first == "02-00 Hidden Track.flac")
        // The disc image starts with it, as track 1's index 00.
        let image = URL(filePath: try #require(record?.image))
        #expect(try AudioEncoder.decode(image).count == 3 * 75 * 588)
        #expect(
            try String(contentsOf: image.deletingPathExtension().appendingPathExtension("cue"), encoding: .utf8)
                .contains(
                    "  TRACK 01 AUDIO\n    TITLE \"Help on the Way >\"\n    PERFORMER \"Grateful Dead\"\n    ISRC USRH11900001\n    INDEX 00 00:00:00\n    INDEX 01 00:01:00\n"
                ))
        let cue = try #require(
            try FileManager.default.contentsOfDirectory(
                at: files[0].deletingLastPathComponent(), includingPropertiesForKeys: nil
            )
            .first { $0.pathExtension == "cue" })
        #expect(
            try String(contentsOf: cue, encoding: .utf8).contains(
                "FILE \"02-00 Hidden Track.flac\" WAVE\n  TRACK 01 AUDIO"))
    }
}
