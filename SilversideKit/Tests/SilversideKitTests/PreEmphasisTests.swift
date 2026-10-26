import Foundation
import Testing

@testable import SilversideKit

struct PreEmphasisTests {
    /// A stereo sine at `frequency`, `amplitude` of full scale, the same in both channels.
    static func sine(_ frequency: Double, amplitude: Double = 0.5, frames: Int = 44_100) -> [UInt32] {
        (0..<frames).map { frame in
            let value = Int16((amplitude * 32767 * sin(2 * .pi * frequency * Double(frame) / 44_100)).rounded())
            let bits = UInt32(UInt16(bitPattern: value))
            return bits | bits << 16
        }
    }

    /// The level of the left channel of `values` (`TrackPCM.wide`), from `start`, in 16-bit units.
    static func rms(_ values: [Int32], from start: Int = 4410) -> Double {
        let left = stride(from: 2 * start, to: values.count, by: 2).map { Double(values[$0]) / 65_536 }
        return (left.reduce(0) { $0 + $1 * $1 } / Double(left.count)).squareRoot()
    }

    /// The filter follows the analog curve of IEC 60908 within 0.1 dB from 20 Hz to 20 kHz:
    /// 0 dB at low frequencies, -9.49 dB at 20 kHz.
    @Test func followsTheAnalogCurve() {
        for step in 0...200 {
            let frequency = 20 * pow(1000, Double(step) / 200)
            let error = DeEmphasis.response(atFrequency: frequency) - DeEmphasis.analogResponse(atFrequency: frequency)
            #expect(abs(error) < 0.1, "\(frequency) Hz")
        }
        #expect(abs(DeEmphasis.analogResponse(atFrequency: 20_000) + 9.49) < 0.005)
        #expect(abs(DeEmphasis.response(atFrequency: 0)) < 1e-12)
    }

    /// A sine comes out at the filter's gain for its frequency.
    @Test(arguments: [100.0, 1000, 5000, 10_000, 16_000])
    func lowersASineByTheCurve(frequency: Double) {
        let samples = Self.sine(frequency)
        let input = Self.rms(TrackPCM.cd(samples).wideValues)
        let output = Self.rms(DeEmphasis.apply(.cd(samples), bits: 20))
        let gain = 20 * log10(output / input)
        #expect(abs(gain - DeEmphasis.response(atFrequency: frequency)) < 0.02, "\(gain) dB")
    }

    /// The values are rounded to 20 bits, and the loudest square wave stays in range.
    @Test func roundsToTheBitsAndNeverClips() {
        let square = (0..<4410).map { $0 / 10 % 2 == 0 ? UInt32(0x7FFF_7FFF) : UInt32(0x8000_8000) }
        let output = DeEmphasis.apply(.cd(square), bits: 20)
        #expect(output.allSatisfy { $0 & 0xFFF == 0 })
        let peak = output.map { abs(Double($0) / 65_536) }.max() ?? 0
        #expect(peak <= 32768 && peak > 30000)
    }

    /// Audio that runs from one track into the next comes out as if the disc were one track:
    /// the end of the track before settles the filter.
    @Test func continuesFromTheTrackBefore() {
        let whole = Self.sine(440, amplitude: 0.9, frames: 20_000)
        let first = Array(whole[..<12_345])
        let second = Array(whole[12_345...])
        let together = DeEmphasis.apply(.cd(whole), bits: 24)
        let split = DeEmphasis.apply(.cd(second), bits: 24, previous: .cd(first))
        #expect(split == Array(together[(2 * 12_345)...]))
        // Started at rest, the second track would begin with a step.
        let cold = DeEmphasis.apply(.cd(second), bits: 24)
        #expect(cold[0] != together[2 * 12_345])
    }

    /// The tags: PRE_EMPHASIS=yes for audio as pressed, DE_EMPHASIZED=yes for audio taken out of it.
    @Test func tagsTheTracks() {
        #expect(PreEmphasis.tags(hasPreEmphasis: true, deEmphasized: false).map(\.key) == ["PRE_EMPHASIS"])
        #expect(PreEmphasis.tags(hasPreEmphasis: true, deEmphasized: true).map(\.key) == ["DE_EMPHASIZED"])
        #expect(PreEmphasis.tags(hasPreEmphasis: false, deEmphasized: false).isEmpty)
    }

    /// A verified rip of three tracks of a 1 kHz and a 10 kHz tone, and the library beside it.
    /// `emphasized` lists the tracks whose control bits say pre-emphasis.
    func makeRip(emphasized: Set<Int>) throws -> (folder: URL, library: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        let folder = root.appending(path: "rip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sectors = 75
        let toc = try TOC(audioTrackStarts: [0, sectors, 2 * sectors], leadOutLBA: 3 * sectors)
        var tracks = [RipReport.Track]()
        for number in 1...3 {
            let audio = zip(Self.sine(1000, frames: sectors * 588), Self.sine(10_000, frames: sectors * 588)).map {
                // Left: 1 kHz; right: 10 kHz.
                $0.0 & 0xFFFF | $0.1 & 0xFFFF_0000
            }
            try WAVFile.write(audio, to: folder.appending(path: "Track 0\(number).wav"))
            var track = RipReport.Track(
                number: number, file: "Track 0\(number).wav", startLBA: (number - 1) * sectors, sectors: sectors,
                preEmphasis: emphasized.contains(number), accurateRip: .accurate)
            track.recordChecksums(of: audio, isFirstTrack: number == 1, isLastTrack: number == 3)
            tracks.append(track)
        }
        var report = RipReport(
            drive: .init(vendor: "V", product: "P", revision: "1", readOffset: 103, offsetSource: "test"),
            secure: true, toc: toc, tracks: tracks, ctdb: .init(status: .verified))
        report.release = MusicBrainzRelease(
            id: "denon", title: "Denon Audio Technical CD", artistCredit: [.init(name: "[no artist]")],
            date: "1984-05", country: "JP", status: "Official", barcode: nil, disambiguation: nil, labels: [],
            releaseGroup: nil,
            media: [
                .init(
                    position: 1, format: "CD", title: nil, discIDs: [],
                    tracks: (1...3).map {
                        .init(
                            position: $0, number: String($0), title: "Tone \($0)", length: 1000,
                            artistCredit: [.init(name: "[no artist]")], recordingID: nil)
                    })
            ], hasFrontCover: false)
        try report.write(to: folder.appending(path: "disc.json"))
        return (folder, root.appending(path: "library"))
    }

    /// Tracks 1 and 2 have pre-emphasis, track 3 not: the first two become 20-bit FLAC files of
    /// their de-emphasis, the third stays bit for bit the disc.
    @Test func deEmphasizesTheFlaggedTracks() throws {
        let (folder, library) = try makeRip(emphasized: [1, 2])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        let (files, record) = try DiscEncoder(format: .flac).encodeWithRecord(disc, into: library)
        #expect(record?.deEmphasizedTracks == [1, 2])
        #expect(record?.checkText.contains("tracks 1-2 de-emphasized, at 20 bits") == true)
        let first = try WAVFile.read(disc.tracks[0].file)
        let second = try WAVFile.read(disc.tracks[1].file)
        #expect(try AudioEncoder.decodeWide(files[0]) == DeEmphasis.apply(.cd(first), bits: 20))
        // Track 2 follows track 1 on the disc, so track 1's end settles its filter.
        #expect(try AudioEncoder.decodeWide(files[1]) == DeEmphasis.apply(.cd(second), bits: 20, previous: .cd(first)))
        #expect(try AudioEncoder.decode(files[2]) == WAVFile.read(disc.tracks[2].file))
        // The 10 kHz channel is about 7.6 dB lower; the 1 kHz one about 0.4 dB.
        let wide = try AudioEncoder.decodeWide(files[0])
        let right = Array(wide.dropFirst())
        let input = TrackPCM.cd(first).wideValues
        #expect(abs(20 * log10(Self.rms(wide) / Self.rms(input)) + 0.36) < 0.05)
        #expect(abs(20 * log10(Self.rms(right) / Self.rms(Array(input.dropFirst()))) + 7.66) < 0.1)
        #expect(try FLACTags.read(files[0]).contains { $0.key == "DE_EMPHASIZED" && $0.value == "yes" })
        #expect(try !FLACTags.read(files[2]).contains { $0.key == "DE_EMPHASIZED" || $0.key == "PRE_EMPHASIS" })
        // The album's files are no longer the ripped audio, so they cannot be encoded again.
        let album = files[0].deletingLastPathComponent()
        #expect(throws: EncodingError.deEmphasized(album)) {
            try RippedDisc(albumReportAt: album.appending(path: "Rip Report.json"))
        }
    }

    /// Kept as pressed, the files are the disc, and the flagged tracks say so in a tag.
    @Test func keepsTheDiscAsPressed() throws {
        let (folder, library) = try makeRip(emphasized: [2])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        var encoder = DiscEncoder(format: .flac)
        encoder.deEmphasizes = false
        let (files, record) = try encoder.encodeWithRecord(disc, into: library)
        #expect(record?.deEmphasizedTracks == nil)
        #expect(try AudioEncoder.decode(files[1]) == WAVFile.read(disc.tracks[1].file))
        #expect(try FLACTags.read(files[1]).contains { $0.key == "PRE_EMPHASIS" && $0.value == "yes" })
        #expect(try !FLACTags.read(files[0]).contains { $0.key == "PRE_EMPHASIS" })
    }

    /// The setting is "ask" until someone chooses, and older settings files lack it.
    @Test func asksByDefault() throws {
        #expect(Settings().preEmphasis == .ask)
        let decoded = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(decoded.preEmphasis == .ask)
        #expect(PreEmphasisChoice(rawValue: "deemphasize") == .deEmphasize)
    }
}

extension TrackPCM {
    /// The values as `TrackPCM.wide` holds them, for comparing levels.
    fileprivate var wideValues: [Int32] {
        switch self {
        case .cd(let samples):
            samples.flatMap {
                [Int32(Int16(truncatingIfNeeded: $0)) << 16, Int32(Int16(truncatingIfNeeded: $0 >> 16)) << 16]
            }
        case .wide(let values): values
        }
    }
}
