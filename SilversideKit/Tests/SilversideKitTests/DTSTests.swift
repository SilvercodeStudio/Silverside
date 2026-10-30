import Foundation
import Testing

@testable import SilversideKit

struct DTSTests {
    /// The header of a DTS core frame, up to its source resolution, as bits: a frame of 1,024
    /// samples, as on *Forever Yours*. `resolution` is the 3-bit code (2 is 20 bits).
    static func headerBits(resolution: Int = 2) -> [Bool] {
        func bits(_ value: Int, _ count: Int) -> [Bool] { (0..<count).reversed().map { value >> $0 & 1 == 1 } }
        return bits(0x7FFE_8001, 32) + bits(1, 1) + bits(31, 5) + bits(0, 1) + bits(31, 7) + bits(3584, 14)
            + bits(9, 6) + bits(8, 4) + bits(29, 5) + bits(0, 5) + bits(0, 4) + bits(1, 1) + bits(2, 2) + bits(1, 1)
            + bits(0, 1) + bits(7, 4) + bits(1, 2) + bits(resolution, 3) + bits(0, 6)
    }

    /// Bits packed 14 to a 16-bit word, little-endian, the top two bits copies of bit 13, as a
    /// DTS-CD has them.
    static func pack14(_ bits: [Bool]) -> [UInt8] {
        var bytes = [UInt8]()
        for start in stride(from: 0, to: bits.count, by: 14) {
            let chunk = bits[start..<min(start + 14, bits.count)]
            var value = chunk.reduce(0) { $0 << 1 | ($1 ? 1 : 0) } << (14 - chunk.count)
            if value & 0x2000 != 0 { value |= 0xC000 }
            bytes += [UInt8(value & 0xFF), UInt8(value >> 8)]
        }
        return bytes
    }

    /// A DTS-CD stream of `count` frames of 4,096 bytes: each a header, its number in bytes 100
    /// to 103, and random words after that, which the 14-bit packing keeps from looking like a
    /// sync word.
    static func stream(frames count: Int, first: Int = 0, resolution: Int = 2, seed: UInt64 = 1) -> [UInt8] {
        var generator = SplitMix64(state: seed)
        var bytes = [UInt8]()
        for number in first..<(first + count) {
            var frame = pack14(headerBits(resolution: resolution))
            while frame.count < 100 { frame.append(0) }
            frame += withUnsafeBytes(of: UInt32(number).littleEndian) { Array($0) }
            while frame.count < 4096 {
                let value = UInt16.random(in: 0...0x1FFF, using: &generator)
                frame += [UInt8(value & 0xFF), UInt8(value >> 8)]
            }
            bytes += frame
        }
        return bytes
    }

    static func samples(_ bytes: [UInt8]) -> [UInt32] {
        precondition(bytes.count % 4 == 0)
        return stride(from: 0, to: bytes.count, by: 4).map {
            UInt32(bytes[$0]) | UInt32(bytes[$0 + 1]) << 8 | UInt32(bytes[$0 + 2]) << 16 | UInt32(bytes[$0 + 3]) << 24
        }
    }

    @Test func findsTheFramesOfAStream() {
        let audio = Self.samples([UInt8](repeating: 0, count: 3000) + Self.stream(frames: 40))
        #expect(DTSStream.isStream(audio))
        let frames = audio.withUnsafeBytes { DTSStream.frames(in: $0) }
        #expect(frames?.packing == .words14LE)
        #expect(frames?.spacing == 4096)
        #expect(frames?.starts == (0..<40).map { 3000 + $0 * 4096 })
    }

    @Test func musicIsNotAStream() {
        #expect(!DTSStream.isStream(PreEmphasisTests.sine(440, frames: 200_000)))
        var generator = SplitMix64(state: 7)
        var noise = (0..<200_000).map { _ in UInt32.random(in: .min ... .max, using: &generator) }
        #expect(!DTSStream.isStream(noise))
        // A few sync words by chance, at no steady spacing.
        for place in [1000, 50_000, 51_234, 120_000] { noise[place] = 0xE800_1FFF }
        #expect(!DTSStream.isStream(noise))
    }

    /// A sync word that music makes by chance inside a frame is not a frame; a frame that a new
    /// stream cuts short is left out.
    @Test func leavesOutAChanceSyncWordAndACutFrame() {
        var bytes = Self.stream(frames: 30)
        // A sync word by chance inside frame 10.
        bytes.replaceSubrange((10 * 4096 + 500)..<(10 * 4096 + 506), with: [0xFF, 0x1F, 0x00, 0xE8, 0xF1, 0x07])
        // The stream begins again 1,000 bytes into frame 20.
        bytes = Array(bytes[0..<(20 * 4096 + 1000)]) + Self.stream(frames: 10, first: 100, seed: 2)
        let frames = bytes.withUnsafeBytes { DTSStream.frames(in: $0) }
        #expect(frames?.starts == (0..<20).map { $0 * 4096 } + (0..<10).map { 20 * 4096 + 1000 + $0 * 4096 })
    }

    @Test func readsTheSourceResolution() {
        for (code, bits) in [(0, 16), (2, 20), (3, 20), (5, 24), (6, 24)] {
            let frame = Self.pack14(Self.headerBits(resolution: code)) + [UInt8](repeating: 0, count: 200)
            #expect(frame.withUnsafeBytes { DTSStream.header(at: 0, in: $0, packing: .words14LE)?.sourceBits } == bits)
        }
    }

    /// Stands in for ffmpeg: each frame gives 1,024 samples of two channels, numbered from the
    /// frame's number, so a sample's value says where it came from. Frames in `fails` give
    /// nothing, as a frame that does not decode.
    static func fakeDecode(_ data: Data, fails: Set<Int> = []) -> SurroundPCM {
        var values = [Int32]()
        for start in stride(from: 0, to: data.count, by: 4096) {
            let number = data[(data.startIndex + start + 100)..<(data.startIndex + start + 104)].enumerated().reduce(0)
            {
                $0 | Int($1.element) << (8 * $1.offset)
            }
            guard !fails.contains(number) else { continue }
            for sample in 0..<1024 {
                let value = Int32((number * 1024 + sample) << 12)
                values += [value, -value]
            }
        }
        return SurroundPCM(values: values, channels: 2, channelMask: 0x3)
    }

    /// What a sample of the decode should be, at `position` on the disc, with the stream
    /// starting at `lead`.
    static func expected(at position: Int, lead: Int, fails: Set<Int> = []) -> Int32 {
        guard position >= lead, !fails.contains((position - lead) / 1024) else { return 0 }
        return Int32((position - lead) << 12)
    }

    /// Frames run across the tracks' starts: with the tracks around it, each sample of a track
    /// is the one a decode of the whole disc has there; without them, the cut frames are silent.
    @Test func placesEachFramesAudioWhereTheFrameIs() throws {
        let lead = 750
        let disc = Self.samples([UInt8](repeating: 0, count: lead * 4) + Self.stream(frames: 60))
        // Tracks that start in the middle of frames.
        let cuts = [0, 20_000, 41_234, disc.count]
        let tracks = (0..<3).map { Array(disc[cuts[$0]..<cuts[$0 + 1]]) }
        for index in 0..<3 {
            let decoded = try DTSDecoder.decode(
                tracks[index], previous: index > 0 ? tracks[index - 1][...] : nil,
                next: index < 2 ? tracks[index + 1][...] : nil
            ) { Self.fakeDecode($0) }
            #expect(decoded.channels == 2)
            #expect(decoded.bits == 20)
            #expect(decoded.frameCount == tracks[index].count)
            let wrong = (0..<decoded.frameCount).filter {
                decoded.values[2 * $0] != Self.expected(at: cuts[index] + $0, lead: lead)
            }
            #expect(wrong.isEmpty, "track \(index + 1)")
        }
        let alone = try DTSDecoder.decode(tracks[1], previous: nil, next: nil) { Self.fakeDecode($0) }
        // The frame that started in track 1 is not there, nor the one that ends in track 3.
        let firstWhole = (20_000 - lead + 1023) / 1024 * 1024 + lead - 20_000
        #expect(alone.values[0..<(2 * firstWhole)].allSatisfy { $0 == 0 })
        #expect(alone.values[2 * firstWhole] == Self.expected(at: 20_000 + firstWhole, lead: lead))
        #expect(alone.values.suffix(2).allSatisfy { $0 == 0 })
    }

    /// A frame that does not decode (*Forever Yours* ends with one) stays silent, and every
    /// other frame is in its place.
    @Test func silencesAFrameThatDoesNotDecode() throws {
        let disc = Self.samples(Self.stream(frames: 50))
        for fails in [Set([49]), Set([7]), Set([7, 30])] {
            let decoded = try DTSDecoder.decode(disc, previous: nil, next: nil) { Self.fakeDecode($0, fails: fails) }
            let wrong = (0..<decoded.frameCount).filter {
                decoded.values[2 * $0] != Self.expected(at: $0, lead: 0, fails: fails)
            }
            #expect(wrong.isEmpty, "frames \(fails.sorted())")
        }
    }

    /// ffmpeg writes WAVE_FORMAT_EXTENSIBLE to a pipe, with sizes it cannot go back to fill in.
    @Test func readsFFmpegsWave() throws {
        func le(_ value: Int, _ bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8(value >> (8 * $0) & 0xFF) } }
        let values: [Int32] = (0..<60).map { Int32($0 - 30) << 12 }
        var wave = Array("RIFF".utf8) + le(0xFFFF_FFFF, 4) + Array("WAVE".utf8)
        wave += Array("fmt ".utf8) + le(40, 4) + le(0xFFFE, 2) + le(6, 2) + le(44_100, 4) + le(44_100 * 24, 4)
        wave += le(24, 2) + le(32, 2) + le(22, 2) + le(32, 2) + le(0x60F, 4) + [UInt8](repeating: 0, count: 16)
        wave += Array("LIST".utf8) + le(4, 4) + Array("INFO".utf8)
        wave += Array("data".utf8) + le(0xFFFF_FFFF, 4) + values.flatMap { le(Int(UInt32(bitPattern: $0)), 4) }
        let audio = try SurroundPCM(wave: Data(wave))
        #expect(audio == SurroundPCM(values: values, channels: 6, channelMask: 0x60F))
        #expect(audio.layoutName == "5.1")
    }

    /// 5.1 in each format that holds it: the lossless ones give back every value in its
    /// channel, and AAC the length.
    @Test(arguments: [AudioFormat.flac, .alac, .aiff, .aac])
    func writesSurroundFiles(format: AudioFormat) throws {
        let frames = 44_100
        // A different tone in each channel, at 20 bits.
        let values = (0..<(frames * 6)).map { index -> Int32 in
            let (frame, channel) = (index / 6, index % 6)
            let tone = sin(2 * .pi * Double(220 * (channel + 1)) * Double(frame) / 44_100)
            return Int32((0.3 * tone * 524_287).rounded()) << 12
        }
        let audio = SurroundPCM(values: values, channels: 6, channelMask: 0x60F, bits: 20)
        let url = FileManager.default.temporaryDirectory.appending(path: "surround-\(UUID()).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioEncoder.encode(audio, format: format, to: url)
        let decoded = try AudioEncoder.decodeSurround(url)
        #expect(decoded.channels == 6)
        if format.isLossless {
            #expect(decoded.values == values)
        } else {
            #expect(abs(decoded.frameCount - frames) < 4 * 1152)
            // Each channel's tone is still in its own channel: the center's is the loudest there.
            let center = stride(from: 2, to: decoded.values.count, by: 6).map { abs(Double(decoded.values[$0])) }
            #expect(center.max()! > 0.2 * 2_147_483_648)
        }
        #expect(throws: DTSError.noSurround(.mp3)) { try AudioEncoder.encode(audio, format: .mp3, to: url) }
    }

    /// BS.1770 weighs the surround channels 1.41 times, and leaves the LFE channel out.
    @Test func weighsSurroundChannels() {
        let tone = PreEmphasisTests.sine(1000, amplitude: 0.25, frames: 5 * 44_100).map {
            Int32(Int16(truncatingIfNeeded: $0)) << 16
        }
        func loudness(inChannel channel: Int) -> Double? {
            var values = [Int32](repeating: 0, count: tone.count * 6)
            for (frame, value) in tone.enumerated() { values[frame * 6 + channel] = value }
            return ReplayGain.analyze(SurroundPCM(values: values, channels: 6, channelMask: 0x60F)).loudness
        }
        let front = loudness(inChannel: 0)!
        let surround = loudness(inChannel: 4)!
        #expect(abs(surround - front - 10 * log10(1.41)) < 0.01)
        #expect(loudness(inChannel: 3) == nil)
    }

    @Test func recordsAStreamInPlaceOfHDCDCodes() {
        var track = RipReport.Track(
            number: 1, file: "Track 01.wav", startLBA: 0, sectors: 10, preEmphasis: false, accurateRip: .accurate)
        track.recordDTS(in: Self.samples(Self.stream(frames: 20)))
        #expect(track.dts == true)
        #expect(track.hdcd == nil)
        track.recordDTS(in: PreEmphasisTests.sine(440))
        #expect(track.dts == nil)
        #expect(DTSStatus([track]) == .noStream)
    }

    /// A rip of three tracks whose audio is one DTS stream across them, as on a DTS-CD. With
    /// `recorded`, its report says so; else it is from before Silverside looked.
    func makeRip(stream: [UInt8], recorded: Bool = true) throws -> (folder: URL, library: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        let folder = root.appending(path: "rip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Whole sectors, the stream after some silence, and silence after it.
        let sectors = (stream.count + 3000 * 4) / CDDA.bytesPerSector / 3 + 1
        var bytes = [UInt8](repeating: 0, count: 1000 * 4) + stream
        bytes += [UInt8](repeating: 0, count: 3 * sectors * CDDA.bytesPerSector - bytes.count)
        let disc = Self.samples(bytes)
        let toc = try TOC(audioTrackStarts: [0, sectors, 2 * sectors], leadOutLBA: 3 * sectors)
        var tracks = [RipReport.Track]()
        for number in 1...3 {
            let size = sectors * CDDA.samplesPerSector
            let audio = Array(disc[((number - 1) * size)..<(number * size)])
            try WAVFile.write(audio, to: folder.appending(path: "Track 0\(number).wav"))
            var track = RipReport.Track(
                number: number, file: "Track 0\(number).wav", startLBA: (number - 1) * sectors, sectors: sectors,
                preEmphasis: false, accurateRip: .accurate)
            track.recordChecksums(of: audio, isFirstTrack: number == 1, isLastTrack: number == 3)
            if recorded { track.recordDTS(in: audio) }
            tracks.append(track)
        }
        var report = RipReport(
            drive: .init(vendor: "V", product: "P", revision: "1", readOffset: 103, offsetSource: "test"),
            secure: true, toc: toc, tracks: tracks, ctdb: .init(status: .verified))
        if recorded { report.dts = DTSStatus(tracks) }
        report.release = MusicBrainzRelease(
            id: "forever", title: "Forever Yours", artistCredit: [.init(name: "Marvin Gaye")], date: "1997",
            country: "US", status: "Official", barcode: nil, disambiguation: nil, labels: [], releaseGroup: nil,
            media: [
                .init(
                    position: 1, format: "DTS CD", title: nil, discIDs: [],
                    tracks: (1...3).map {
                        .init(
                            position: $0, number: String($0), title: "Song \($0)", length: 1000,
                            artistCredit: [.init(name: "Marvin Gaye")], recordingID: nil)
                    })
            ], hasFrontCover: false)
        try report.write(to: folder.appending(path: "disc.json"))
        return (folder, root.appending(path: "library"))
    }

    /// Kept, the stream is bit for bit the disc, tagged MEDIA=DTS CD, with no ReplayGain: it
    /// is not audio a player plays. A lossy format would turn it into noise, so it refuses.
    @Test func keepsTheStreamInALosslessFormatOnly() throws {
        let (folder, library) = try makeRip(stream: Self.stream(frames: 120))
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        #expect(try DiscEncoder(format: .flac).dtsTracks(of: disc) == [1, 2, 3])
        let (files, record) = try DiscEncoder(format: .flac).encodeWithRecord(disc, into: library)
        for (file, track) in zip(files, disc.tracks) {
            #expect(try AudioEncoder.decode(file) == WAVFile.read(track.file))
            let tags = try FLACTags.read(file)
            #expect(tags.contains { $0.key == "MEDIA" && $0.value == "DTS CD" })
            #expect(!tags.contains { $0.key.hasPrefix("REPLAYGAIN") || $0.key == "DTS" })
        }
        #expect(record?.replayGain == nil)
        #expect(record?.dtsDecoded == nil)
        // Music would play the stream as static, so a kept stream with no decode gives it nothing.
        var again = DiscEncoder(format: .flac)
        again.overwrites = true
        let kept = try again.encodeWithRecord(disc, into: library, dts: .keep)
        #expect(kept.holdsStream && kept.musicFiles.files.isEmpty)
        #expect(throws: DTSError.lossyStream(.aac)) {
            try DiscEncoder(format: .aac).encodeWithRecord(disc, into: library)
        }
        var decoder = DiscEncoder(format: .mp3)
        decoder.decodesDTS = true
        #expect(throws: DTSError.noSurround(.mp3)) { try decoder.encodeWithRecord(disc, into: library) }
    }

    /// A rip from before Silverside looked for DTS is looked at when it is encoded.
    @Test func findsTheStreamInAnOlderRip() throws {
        let (folder, _) = try makeRip(stream: Self.stream(frames: 120), recorded: false)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        #expect(disc.report?.dts == nil)
        #expect(try DiscEncoder(format: .flac).dtsTracks(of: disc) == [1, 2, 3])
    }

    /// A stream from ffmpeg's own DTS encoder (5.1, 16-bit words, 512 samples a frame), and its
    /// decode by ffmpeg as one piece.
    static func ffmpegStream(seconds: Int) throws -> (stream: [UInt8], decode: SurroundPCM) {
        let ffmpeg = FFmpeg.program()!
        let file = FileManager.default.temporaryDirectory.appending(path: "dts-\(UUID()).dts")
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds):sample_rate=44100", "-af",
            "pan=5.1(side)|FL=c0|FR=0.5*c0|FC=0.25*c0|LFE=0.1*c0|SL=0.3*c0|SR=0.2*c0", "-c:a", "dca", "-strict", "-2",
            "-b:a", "1411200", "-f", "dts", file.path,
        ]
        try process.run()
        process.waitUntilExit()
        let stream = [UInt8](try Data(contentsOf: file))
        return (stream, try FFmpeg.decodeDTS(Data(stream), ffmpeg: ffmpeg))
    }

    /// With ffmpeg: the decoded copy beside the album is the decode of the whole stream, cut at
    /// the tracks' starts, 5.1 FLAC files tagged DTS=decoded, with ReplayGain.
    @Test(.enabled(if: FFmpeg.program() != nil)) func decodesTheStreamWithFFmpeg() throws {
        let (stream, whole) = try Self.ffmpegStream(seconds: 4)
        let (folder, library) = try makeRip(stream: stream)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        let result = try DiscEncoder(format: .flac).encodeWithRecord(disc, into: library, dts: .decode)
        #expect(result.files.count == 3)
        #expect(result.copyFiles.count == 3)
        // Music gets the decoded copy, not the stream (Apple Lossless or FLAC alike).
        #expect(result.musicFiles.files == result.copyFiles && result.musicFiles.format == .flac)
        #expect(result.copyEncoding?.dtsDecoded == "5.1")
        #expect(result.copyEncoding?.albumSuffix == " (DTS 5.1)")
        #expect(result.copyEncoding?.replayGain?.album != nil)
        #expect(result.copyFiles[0].deletingLastPathComponent().lastPathComponent == "Forever Yours (DTS 5.1)")
        let tags = try FLACTags.read(result.copyFiles[0])
        #expect(tags.contains { $0.key == "DTS" && $0.value == "decoded" })
        // The tracks one after another are the whole stream's decode, after the silence before it.
        let decoded = try result.copyFiles.map { try AudioEncoder.decodeSurround($0) }
        // FLAC's six channels are 5.1, whose surrounds Core Audio calls back ones (0x3F).
        #expect(decoded.allSatisfy { $0.channels == 6 && $0.layoutName == "5.1" })
        let values = decoded.flatMap(\.values)
        let lead = 1000 * 6
        let source = stream.withUnsafeBytes { DTSStream.header(at: 0, in: $0, packing: .words16BE)?.sourceBits }
        let mask = ~Int32((1 << (32 - (source == 24 ? 24 : 20))) - 1)
        #expect(values[0..<lead].allSatisfy { $0 == 0 })
        let expected = whole.values.map { $0 & mask }
        let wrong = zip(values[lead..<(lead + expected.count)], expected).filter { $0 != $1 }.count
        #expect(wrong == 0)
        #expect(values[(lead + expected.count)...].allSatisfy { $0 == 0 })
    }
}

/// Playback looks at the first second with sound for a DTS stream, past digital silence.
struct DTSPlaybackCheckTests {
    /// Seconds of digital silence, then a stream (the reviewer's case, 2026-10-29); and a quiet
    /// intro of music, which is not one.
    @Test func findsAStreamAfterSilence() {
        let stream = DTSTests.samples(DTSTests.stream(frames: 100))
        let file = [UInt32](repeating: 0, count: 3 * 44_100) + stream
        func reader(_ samples: [UInt32]) -> (Int, Int) -> [UInt32]? {
            { start, count in start < samples.count ? Array(samples[start..<min(start + count, samples.count)]) : nil }
        }
        #expect(DTSPlaybackCheck.holdsStream(read: reader(file)))
        let quiet = (0..<(3 * 44_100)).map { UInt32(UInt16(bitPattern: Int16(($0 % 7) - 3))) * 0x1_0001 }
        #expect(!DTSPlaybackCheck.holdsStream(read: reader(quiet + stream)))
        #expect(!DTSPlaybackCheck.holdsStream(read: reader([UInt32](repeating: 0, count: 44_100))))
    }

    /// From the disc, a second at a time: silence plays at once, and a piece that ends just
    /// after the stream starts waits for the next.
    @Test func decidesFromASecondOfSound() {
        let stream = DTSTests.samples(DTSTests.stream(frames: 100))
        let samples = [UInt32](repeating: 0, count: 2 * 44_100 - 512) + stream
        let pieces = stride(from: 0, to: samples.count, by: 44_100).map {
            Array(samples[$0..<min($0 + 44_100, samples.count)])
        }
        var check = DTSPlaybackCheck.Pieces()
        #expect(check.add(pieces[0], isLast: false) == .play([pieces[0]]))
        #expect(check.add(pieces[1], isLast: false) == .wait)
        #expect(check.add(pieces[2], isLast: false) == .decided(isStream: true, pieces: [pieces[1], pieces[2]]))
        #expect(check.add(pieces[3], isLast: false) == .play([pieces[3]]))

        // A short track decides at its end; music is no stream.
        var music = DTSPlaybackCheck.Pieces()
        let tone = PreEmphasisTests.sine(440, amplitude: 0.1, frames: 4000)
        #expect(music.add(tone, isLast: true) == .decided(isStream: false, pieces: [tone]))
    }
}
