import Foundation
import Testing

@testable import SilversideKit

struct HDCDTests {
    /// Audio with HDCD codes in the lowest bit of both channels, as an HDCD master hides them.
    /// The decoder reads the bits through a descrambler (bit k of its window XOR bits k + 5
    /// and k + 23), so the bits are scrambled here to match. Each packet is a sync word and a
    /// control code: type A has an 8-bit code, type B a 16-bit code (the code, then its
    /// inverse, which `check` replaces to make the packet damaged).
    struct Encoder {
        enum Packet {
            case a(UInt8)
            case b(UInt8, check: UInt8? = nil)
        }

        private var lsb = [Bool]()
        private var plain = [Bool]()

        /// `count` bits that ask for nothing.
        mutating func pause(_ count: Int) {
            for _ in 0..<count { add(false) }
        }

        mutating func add(_ packet: Packet) {
            switch packet {
            case .a(let code):
                add(0x7e0f_a005, bits: 32)
                add(UInt32(code), bits: 8)
            case .b(let code, let check):
                add(0x7e0f_a006, bits: 32)
                add(UInt32(code), bits: 8)
                add(UInt32(check ?? ~code), bits: 8)
            }
        }

        private mutating func add(_ value: UInt32, bits: Int) {
            for bit in (0..<bits).reversed() { add(value >> bit & 1 == 1) }
        }

        private mutating func add(_ bit: Bool) {
            plain.append(bit)
            let n = lsb.count
            let earlier = (n >= 5 && lsb[n - 5]) != (n >= 23 && lsb[n - 23])
            lsb.append(bit != earlier)
        }

        /// A quiet 440 Hz tone, the same in both channels, with the bits in its lowest bit.
        var samples: [UInt32] { samples(amplitude: 3000) }

        /// The tone at `amplitude`: above 22913 (-3.1 dBFS), peak extend changes it.
        func samples(amplitude: Double) -> [UInt32] {
            lsb.enumerated().map { index, bit in
                let tone = Int16(amplitude * sin(2 * .pi * 440 * Double(index) / 44100)) & ~1 | (bit ? 1 : 0)
                return UInt32(UInt16(bitPattern: tone)) * 0x1_0001
            }
        }
    }

    /// Ten seconds of `packet`, ten times a second, which is how often HDCD masters send them.
    func track(_ packet: Encoder.Packet, seconds: Int = 10, amplitude: Double = 3000) -> [UInt32] {
        var encoder = Encoder()
        for _ in 0..<(10 * seconds) {
            encoder.pause(4410 - 40)
            encoder.add(packet)
        }
        return encoder.samples(amplitude: amplitude)
    }

    @Test func findsCodesThatAskForNothing() throws {
        let codes = try #require(HDCDCodes.scan(track(.a(0))))
        // Both channels count each packet.
        #expect(codes == HDCDCodes(packets: 200))
        #expect(!codes.changesAudio)
        #expect(codes.featuresText == "nothing")
    }

    /// Type A doubles its 3-bit gain into half-dB steps: 3 is -3.0 dB.
    @Test func readsPeakExtendAndGainFromTypeA() throws {
        let codes = try #require(HDCDCodes.scan(track(.a(0x10 | 3))))
        #expect(codes == HDCDCodes(packets: 200, peakExtend: .always, maxGainAdjustment: -3))
        #expect(codes.changesAudio)
        #expect(codes.featuresText == "peak extend, gain down to -3.0 dB")
    }

    /// Type B has a 4-bit gain in half-dB steps (5 is -2.5 dB), and the transient filter bit.
    @Test func readsTypeBAndCountsDamagedPackets() throws {
        var encoder = Encoder()
        for index in 0..<100 {
            encoder.pause(4410 - 48)
            encoder.add(index % 10 == 9 ? .b(0x25, check: 0x00) : index < 50 ? .b(0x05) : .b(0x20))
        }
        let codes = try #require(HDCDCodes.scan(encoder.samples))
        #expect(codes == HDCDCodes(packets: 180, maxGainAdjustment: -2.5, transientFilter: true, errors: 20))
        #expect(codes.featuresText == "gain down to -2.5 dB")
    }

    @Test func findsNoCodesInPlainAudio() {
        var random = SplitMix64(state: 7)
        let noise = (0..<441_000).map { _ in UInt32(truncatingIfNeeded: random.next()) }
        #expect(HDCDCodes.scan(noise) == nil)
        #expect(HDCDCodes.scan([UInt32](repeating: 0, count: 44100)) == nil)
        // Codes in one channel only are not HDCD.
        let left = track(.a(0)).map { $0 & 0xFFFF }
        #expect(HDCDCodes.scan(left) == nil)
    }

    @Test func sumsUpTheTracksOfARip() {
        func track(_ number: Int, _ codes: HDCDCodes?) -> RipReport.Track {
            var track = RipReport.Track(
                number: number, file: "Track 0\(number).wav", startLBA: 0, sectors: 1, preEmphasis: false,
                accurateRip: .accurate)
            track.hdcd = codes
            return track
        }
        var report = RipReport(
            drive: .init(vendor: "", product: "", revision: "", readOffset: 0, offsetSource: ""), secure: true,
            toc: try! TOC(ctdbTOCString: "0:15000:30000"), tracks: [track(1, nil), track(2, nil)],
            ctdb: .init(status: .notChecked))
        #expect(report.hdcdText == nil)
        report.hdcd = HDCDStatus(report.tracks)
        #expect(report.hdcd == .noCodes && report.hdcdText == nil)

        report.tracks = [track(1, HDCDCodes(packets: 9)), track(2, HDCDCodes(packets: 9))]
        report.hdcd = HDCDStatus(report.tracks)
        #expect(report.hdcd == .codesOnly)
        #expect(report.hdcdText?.hasPrefix("HDCD: every track has HDCD codes, but") == true)

        report.tracks[1].hdcd?.peakExtend = .sometimes
        report.tracks.append(track(3, nil))
        report.hdcd = HDCDStatus(report.tracks)
        #expect(report.hdcd == .featuresUsed)
        #expect(report.hdcdText?.contains("2 of 3 tracks have HDCD codes") == true)
        #expect(report.hdcdText?.contains("(peak extend in places in track 2)") == true)
        report.tracks[0].hdcd = HDCDCodes(packets: 9, peakExtend: .always, maxGainAdjustment: -4)
        report.tracks[1].hdcd?.maxGainAdjustment = -0.5
        report.tracks[2].hdcd = HDCDCodes(packets: 9, peakExtend: .always, maxGainAdjustment: -4)
        #expect(
            report.hdcdText?.contains(
                "(peak extend in tracks 1 and 3; peak extend in places in track 2; gain down to -4.0 dB in tracks 1"
                    + " and 3, -0.5 dB in track 2)") == true)
    }

    // MARK: Decoding

    /// Without peak extend or a gain adjustment, the decode is the audio 15 bits up: the same
    /// audio, 6.02 dB lower. Peak extend raises the samples above -3.1 dBFS.
    @Test func decodesOnlyWhatTheCodesChange() {
        /// The samples 15 bits up, interleaved.
        func shifted(_ samples: [UInt32]) -> [Int32] {
            samples.flatMap {
                [Int32(Int16(truncatingIfNeeded: $0)) << 15, Int32(Int16(truncatingIfNeeded: $0 >> 16)) << 15]
            }
        }
        let plain = track(.a(0), seconds: 2, amplitude: 30000)
        #expect(HDCDCodes.decode(plain) == shifted(plain))

        let extended = track(.a(0x10), seconds: 2, amplitude: 30000)
        let decoded = HDCDCodes.decode(extended)
        let expected = shifted(extended)
        let lifted = zip(decoded, expected).filter { $0 != $1 }
        #expect(!lifted.isEmpty)
        // Only samples at or above the peak-extend level (22913 of 32768) change, and they grow.
        #expect(lifted.allSatisfy { abs(Int($1)) >= 22913 << 15 && abs(Int($0)) > abs(Int($1)) })
        #expect(decoded.allSatisfy { $0 & 0xFF == 0 })
        // Below the peak-extend level, the audio is as it was.
        let quiet = track(.a(0x10), seconds: 2, amplitude: 3000)
        #expect(HDCDCodes.decode(quiet) == shifted(quiet))
    }

    /// FLAC and Apple Lossless keep 20 bits of a decode, AIFF and WAV 24.
    @Test func writesAndReadsWideFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let samples = track(.a(0x13), seconds: 2, amplitude: 30000)
        let values = HDCDCodes.decode(samples)
        #expect(values.contains { $0 & 0xF00 != 0 })
        for format in [AudioFormat.flac, .alac, .aiff] {
            let file = folder.appending(path: "t.\(format.rawValue)")
            let decoded = HDCDCodes.decode(samples, bits: format.wideBits)
            #expect(decoded.allSatisfy { $0 & ((1 << (32 - format.wideBits)) - 1) == 0 })
            try AudioEncoder.encode(.wide(decoded), format: format, to: file)
            #expect(try AudioEncoder.decodeWide(file) == decoded, "\(format)")
        }
        // A 20-bit format cuts the bits below 20, so 24-bit values would not survive.
        let cut = folder.appending(path: "cut.flac")
        try AudioEncoder.encode(.wide(values), format: .flac, to: cut)
        #expect(try AudioEncoder.decodeWide(cut) == values.map { $0 & ~0xFFF })
        let wav = folder.appending(path: "t.wav")
        try WAVFile.write(.wide(values), to: wav)
        #expect(try AudioEncoder.decodeWide(wav) == values)
        let aac = folder.appending(path: "t.m4a")
        try AudioEncoder.encode(.wide(values), format: .aac, to: aac)
        #expect(abs(try AudioEncoder.decodeWide(aac).count - values.count) < 8 * 1152)
        // ReplayGain reads both widths alike: the 16-bit audio 16 bits up is the same audio.
        let cd = Array(AudioEncoderTests.samples.prefix(88_200))
        let wide = cd.flatMap {
            [Int32(Int16(truncatingIfNeeded: $0)) << 16, Int32(Int16(truncatingIfNeeded: $0 >> 16)) << 16]
        }
        let a = ReplayGain.analyze(cd)
        let b = ReplayGain.analyze(.wide(wide))
        #expect(a.peak == b.peak && abs((a.loudness ?? 0) - (b.loudness ?? 1)) < 1e-9)
    }

    /// A rip of two tracks with HDCD codes, as `DiscRip` writes it: the codes and the CRC-32s in its report.
    /// A verified rip of a disc with HDCD codes in every track, and the library beside it. With
    /// `sets`, the release has two discs: disc 1 of two tracks and disc 2 of three, ripped in `root`.
    func makeRip(
        _ packet: Encoder.Packet, position: Int = 1, set: Bool = false, root: URL? = nil
    ) throws -> (folder: URL, library: URL) {
        let root = root ?? FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        let folder = root.appending(path: "rip\(position)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let samples = track(packet, seconds: 2, amplitude: 30000)
        let sectors = samples.count / 588
        let count = position == 1 ? 2 : 3
        let toc = try TOC(audioTrackStarts: (0..<count).map { $0 * sectors }, leadOutLBA: count * sectors)
        var tracks = [RipReport.Track]()
        for number in 1...count {
            let audio = Array(samples.prefix(sectors * 588))
            try WAVFile.write(audio, to: folder.appending(path: "Track 0\(number).wav"))
            var track = RipReport.Track(
                number: number, file: "Track 0\(number).wav", startLBA: (number - 1) * sectors, sectors: sectors,
                preEmphasis: false, accurateRip: .accurate)
            track.recordChecksums(of: audio, isFirstTrack: number == 1, isLastTrack: number == count)
            track.hdcd = HDCDCodes.scan(audio)
            tracks.append(track)
        }
        func named(_ position: Int, _ title: String) -> MusicBrainzRelease.Track {
            .init(
                position: position, number: String(position), title: title, length: 2000,
                artistCredit: [.init(name: "Grateful Dead")], recordingID: "rec\(position)")
        }
        var report = RipReport(
            drive: .init(vendor: "V", product: "P", revision: "1", readOffset: 103, offsetSource: "test"),
            secure: true, toc: toc, tracks: tracks, ctdb: .init(status: .verified))
        report.hdcd = HDCDStatus(tracks)
        let disc1 = MusicBrainzRelease.Medium(
            position: 1, format: "HDCD", title: nil, discIDs: [],
            tracks: [named(1, "Hell in a Bucket"), named(2, "Dupree's Diamond Blues")])
        let disc2 = MusicBrainzRelease.Medium(
            position: 2, format: "HDCD", title: nil, discIDs: [],
            tracks: [named(1, "Bird Song"), named(2, "Space"), named(3, "Wharf Rat")])
        report.release = MusicBrainzRelease(
            id: "knick", title: "Dozin' at the Knick", artistCredit: [.init(name: "Grateful Dead")],
            date: "1996-10-29", country: "US", status: "Official", barcode: nil, disambiguation: nil, labels: [],
            releaseGroup: nil, media: set ? [disc1, disc2] : [disc1], hasFrontCover: false)
        try report.write(to: folder.appending(path: "disc.json"))
        return (folder, root.appending(path: "library"))
    }

    @Test func encodesTheDecodeAtTwentyBitsInFLAC() throws {
        let (folder, library) = try makeRip(.a(0x13))
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        #expect(disc.report?.hdcd == .featuresUsed)
        var encoder = DiscEncoder(format: .flac)
        encoder.decodesHDCD = true
        let (files, record) = try encoder.encodeWithRecord(disc, into: library)
        #expect(record?.hdcdDecoded == true && record?.checkText.contains("HDCD decoded, at 20 bits") == true)
        #expect(
            try AudioEncoder.decodeWide(files[0]) == HDCDCodes.decode(try WAVFile.read(disc.tracks[0].file), bits: 20))
        let tags = try FLACTags.read(files[0])
        #expect(tags.contains { $0.key == "HDCD" && $0.value == "decoded" })
        #expect(tags.contains { $0.key == "MEDIA" && $0.value == "HDCD" })
        // The gain is measured on the decode: 6.02 dB lower than the disc, and 3 dB more for the
        // codes' gain adjustment, less what peak extend gives back to this loud tone.
        let gain = try #require(record?.replayGain?.tracks.first?.values.gain)
        let kept = try DiscEncoder(format: .flac).encodeWithRecord(
            disc, into: library.deletingLastPathComponent().appending(path: "kept"))
        let keptGain = try #require(kept.encoding?.replayGain?.tracks.first?.values.gain)
        #expect(gain - keptGain > 6 && gain - keptGain < 9.1)
        #expect(kept.encoding?.hdcdDecoded == nil)
        // Kept as pressed, the files say the disc is HDCD, and nothing more.
        let keptTags = try FLACTags.read(kept.files[0])
        #expect(
            !keptTags.contains { $0.key == "HDCD" } && keptTags.contains { $0.key == "MEDIA" && $0.value == "HDCD" })
    }

    @Test func leavesADiscWhoseCodesAskForNothing() throws {
        let (folder, library) = try makeRip(.a(0))
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        var encoder = DiscEncoder(format: .flac)
        encoder.decodesHDCD = true
        let disc = try RippedDisc(folder: folder)
        let (files, record) = try encoder.encodeWithRecord(disc, into: library)
        #expect(record?.hdcdDecoded == nil)
        #expect(try AudioEncoder.decode(files[0]) == WAVFile.read(disc.tracks[0].file))
        #expect(try FLACTags.read(files[0]).contains { $0.key == "MEDIA" && $0.value == "HDCD" })
    }

    /// The album as pressed, then a decoded copy beside it made from the album's own files.
    @Test func decodesACopyBesideTheAlbumFromItsFiles() throws {
        let (folder, library) = try makeRip(.a(0x10))
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let (files, _) = try DiscEncoder(format: .flac).encodeWithRecord(try RippedDisc(folder: folder), into: library)
        let album = files[0].deletingLastPathComponent()
        let source = try RippedDisc(albumReportAt: album.appending(path: "Rip Report.json"))
        #expect(source.tracks.map(\.file) == files)

        var encoder = DiscEncoder(format: .alac)
        encoder.decodesHDCD = true
        encoder.albumSuffix = " (HDCD)"
        let (copies, record) = try encoder.encodeWithRecord(source, into: library)
        let copyFolder = copies[0].deletingLastPathComponent()
        #expect(copyFolder.lastPathComponent == "Dozin' at the Knick (HDCD)")
        #expect(record?.albumSuffix == " (HDCD)" && record?.hdcdDecoded == true)
        let tags = try MP4Tags.read(copies[0]).comments
        #expect(tags.contains { $0.key == "ALBUM" && $0.value == "Dozin' at the Knick (HDCD)" })
        #expect(tags.contains { $0.key == "HDCD" && $0.value == "decoded" })
        #expect(try AudioEncoder.decodeWide(copies[0]) == HDCDCodes.decode(try AudioEncoder.decode(files[0]), bits: 20))
        // The album as pressed is untouched, and its report still names its own files.
        #expect(try RipReport.read(from: album.appending(path: "Rip Report.json")).encoding?.hdcdDecoded == nil)

        // A library update keeps the copy's title, folder, and tag.
        let update = try DiscEncoder(format: .alac).updateLibrary(
            reportAt: copyFolder.appending(path: "Rip Report.json"), library: library)
        #expect(update.albumFolder?.lastPathComponent == "Dozin' at the Knick (HDCD)" && update.renamed == 0)
        #expect(try MP4Tags.read(copies[0]).comments.contains { $0.key == "HDCD" })

        // A decode is not a source for another, and a file that changed is refused.
        #expect(throws: EncodingError.alreadyDecoded(copyFolder)) {
            try RippedDisc(albumReportAt: copyFolder.appending(path: "Rip Report.json"))
        }
        try AudioEncoder.encode(Array(AudioEncoderTests.samples.prefix(88_200)), format: .flac, to: files[1])
        #expect(throws: EncodingError.sourceChanged(files[1])) {
            try encoder.encodeWithRecord(source, into: library.appending(path: "again"))
        }
    }

    @Test func decodesInPlaceOnlyWhenEveryTrackIsChecked() throws {
        let (folder, library) = try makeRip(.a(0x10))
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let (files, _) = try DiscEncoder(format: .flac).encodeWithRecord(try RippedDisc(folder: folder), into: library)
        let album = files[0].deletingLastPathComponent()
        let report = album.appending(path: "Rip Report.json")
        let original = try Data(contentsOf: files[0])
        let pressed = try Data(contentsOf: files[1])
        var encoder = DiscEncoder(format: .flac)
        encoder.decodesHDCD = true
        encoder.overwrites = true
        encoder.replayGain = false  // which would read track 2 before any track is encoded

        // Track 2 changed since the rip: track 1, though decoded and checked, stays as pressed.
        try AudioEncoder.encode(Array(AudioEncoderTests.samples.prefix(88_200)), format: .flac, to: files[1])
        #expect(throws: EncodingError.sourceChanged(files[1])) {
            try encoder.encodeWithRecord(try RippedDisc(albumReportAt: report), into: library)
        }
        #expect(try Data(contentsOf: files[0]) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: album.path).allSatisfy { !$0.hasPrefix(".") })
        #expect(try RipReport.read(from: report).encoding?.hdcdDecoded == nil)

        try pressed.write(to: files[1])
        let (decoded, record) = try encoder.encodeWithRecord(try RippedDisc(albumReportAt: report), into: library)
        #expect(decoded == files && record?.hdcdDecoded == true)
        #expect(try RipReport.read(from: report).encoding?.hdcdDecoded == true)
        let ripped = try WAVFile.read(folder.appending(path: "Track 01.wav"))
        #expect(try AudioEncoder.decodeWide(files[0]) == HDCDCodes.decode(ripped, bits: 20))
    }

    @Test func decodesADiscWhoseCodesAskForNothingWhenTheOtherDiscsAreDecoded() throws {
        let (first, library) = try makeRip(.a(0x13), set: true)
        let root = first.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let (second, _) = try makeRip(.a(0), position: 2, set: true, root: root)
        var encoder = DiscEncoder(format: .flac)
        encoder.decodesHDCD = true
        #expect(
            try encoder.encodeWithRecord(try RippedDisc(folder: first), into: library).encoding?.hdcdDecoded == true)
        // Disc 2's codes ask for nothing, and the setting keeps it as pressed, but disc 1 holds the decode.
        let (files, record) = try DiscEncoder(format: .flac).encodeWithRecord(
            try RippedDisc(folder: second), into: library)
        #expect(record?.hdcdDecoded == true)
        #expect(try FLACTags.read(files[0]).contains { $0.key == "HDCD" && $0.value == "decoded" })
        // A decode of audio the codes do not change is the audio 6.02 dB lower, exactly.
        let ripped = try WAVFile.read(second.appending(path: "Track 01.wav"))
        #expect(try AudioEncoder.decodeWide(files[0]) == HDCDCodes.decode(ripped, bits: 20))
    }

    @Test func readsTheChoiceFromTheSettings() throws {
        #expect(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).hdcd == .ask)
        #expect(try JSONDecoder().decode(Settings.self, from: Data(#"{"hdcd":"decode"}"#.utf8)).hdcd == .decode)
        var settings = Settings()
        settings.hdcd = .decode
        #expect(DiscEncoder(settings: settings).decodesHDCD)
        settings.hdcd = .ask
        #expect(!DiscEncoder(settings: settings).decodesHDCD)
    }
}
