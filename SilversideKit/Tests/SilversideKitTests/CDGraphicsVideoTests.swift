import AVFoundation
import Foundation
import Testing

@testable import SilversideKit

struct CDGraphicsVideoTests {
    static func pack(_ instruction: UInt8, _ data: [UInt8]) -> [UInt8] {
        CDGraphics.pack(
            command: 9, instruction: instruction, data: data + [UInt8](repeating: 0, count: 16 - data.count))
    }

    /// The instructions draw as a CD+G player does: the color table, memory and border presets,
    /// tiles and XOR tiles, and scrolling; CD+EG's packs draw nothing.
    @Test func drawsTheScreen() {
        var screen = CDGraphicsScreen()
        // Colors 0 to 7: 0 black, 1 red (F00), 2 green (0F0), 3 blue (00F).
        screen.apply(Self.pack(30, [0, 0, 0x3C, 0, 0x03, 0x30, 0, 0x0F]))
        #expect(screen.colors[1] == 0xF00 && screen.colors[2] == 0x0F0 && screen.colors[3] == 0x00F)
        screen.apply(Self.pack(1, [1, 0]))
        #expect(screen.pixels.allSatisfy { $0 == 1 })
        // A preset repeated later in its series does not clear again.
        screen.apply(Self.pack(1, [2, 5]))
        #expect(screen.pixels.allSatisfy { $0 == 1 })
        screen.apply(Self.pack(2, [3]))
        #expect(screen.pixels[0] == 3 && screen.pixels[12 * 300 + 6] == 1)
        // A tile at row 1, column 1 (x 6, y 12): its top line's left half color 2, the rest 0.
        screen.apply(Self.pack(6, [0, 2, 1, 1, 0b111000]))
        #expect(
            screen.pixels[12 * 300 + 6] == 2 && screen.pixels[12 * 300 + 9] == 0 && screen.pixels[13 * 300 + 6] == 0)
        // XOR: 2 ^ 3 = 1 where the bit is set.
        screen.apply(Self.pack(38, [0, 3, 1, 1, 0b100000]))
        #expect(screen.pixels[12 * 300 + 6] == 1 && screen.pixels[12 * 300 + 7] == 2)
        // A scroll copy one tile left wraps column 1 to column 0.
        screen.apply(Self.pack(24, [0, 0x20, 0]))
        #expect(screen.pixels[12 * 300 + 0] == 1 && screen.pixels[12 * 300 + 1] == 2)
        // A scroll preset down fills the top with the color; the fine offsets are kept.
        screen.apply(Self.pack(20, [2, 0x03, 0x15]))
        #expect(screen.pixels[0] == 2 && screen.pixels[24 * 300 + 1] == 2)
        #expect(screen.horizontalOffset == 3 && screen.verticalOffset == 5)
        let before = screen
        screen.apply(CDGraphics.pack(command: 10, instruction: 6, data: [UInt8](repeating: 9, count: 16)))
        #expect(screen == before)
    }

    static func extendedPack(_ instruction: UInt8, _ data: [UInt8]) -> [UInt8] {
        CDGraphics.pack(
            command: 10, instruction: instruction, data: data + [UInt8](repeating: 0, count: 16 - data.count))
    }

    /// MEMORY control with DM and WM, in every data symbol.
    static func memoryControl(_ mode: UInt8, _ memory: UInt8) -> [UInt8] {
        extendedPack(3, [UInt8](repeating: mode << 2 | memory, count: 16))
    }

    /// A CD+EG player (IEC 60908 clause 23): in the 1-plane state each pixel is the SECONDARY's
    /// 4 bits over the PRIMARY's, an index into 256 colors of 6 bits a channel, which show
    /// from the next MEMORY control; a CD+G player shows the PRIMARY in its 16 colors.
    @Test func drawsCDEGsOnePlaneState() {
        var packs = [
            Self.pack(30, [0, 0, 0x3C, 0]),  // CD+G: 0 black, 1 red
            Self.memoryControl(0, 3),
            Self.pack(1, [1, 0]),  // PRIMARY all 1, SECONDARY all 0
            // CD+EG's color 0x21 (SECONDARY 2, PRIMARY 1): main group 4 (colors 32 to 39), the
            // second color: red 0, green 15, blue 0 (upper bits); additional group 2 (32 to 47),
            // the second: blue's low bits 3.
            Self.extendedPack(16 + 4, [0, 0, 0x03, 0x30]),
            Self.extendedPack(48 + 2, [0, 0x03]),
        ]
        // A tile of the SECONDARY at row 1, column 1, its top line's left half 2.
        packs.append(Self.extendedPack(6, [0, 2, 1, 1, 0b111000]))
        var player = CDGraphicsScreen(extended: true)
        for pack in packs { player.apply(pack) }
        // Not shown yet: the colors wait for the next MEMORY control.
        #expect(player.extendedColors[33] == 0 && player.secondary[12 * 300 + 6] == 2)
        player.apply(Self.memoryControl(0, 3))
        #expect(player.extendedColors[33] == 0xF03 && player.displayMode == 0)
        let rgb = player.rgb()
        let at = (12 * 300 + 6) * 3
        #expect(Array(rgb[at..<(at + 3)]) == [0, 243, 12])

        // A CD+G player shows the same packs as the CD+G picture: red.
        var cdg = CDGraphicsScreen()
        for pack in packs + [Self.memoryControl(0, 3)] { cdg.apply(pack) }
        #expect(Array(cdg.rgb()[at..<(at + 3)]) == [255, 0, 0] && cdg.secondary.allSatisfy { $0 == 0 })
    }

    /// The 2-plane state: the CD+G instructions draw in the memories that WM names, each with
    /// its 16 colors, and DM shows one of them or the two added.
    @Test func drawsCDEGsTwoPlaneState() {
        var player = CDGraphicsScreen(extended: true)
        player.apply(Self.memoryControl(1, 1))
        player.apply(Self.pack(30, [0, 0, 0x20, 0]))  // PRIMARY: 1 is red 8
        player.apply(Self.pack(1, [1, 0]))
        player.apply(Self.memoryControl(1, 2))
        player.apply(Self.pack(30, [0, 0, 0x00, 0x08]))  // SECONDARY: 1 is blue 8
        player.apply(Self.pack(1, [1, 0]))
        #expect(player.pixels.allSatisfy { $0 == 1 } && player.secondary.allSatisfy { $0 == 1 })
        #expect(Array(player.rgb()[0..<3]) == [0x88, 0, 0])
        player.apply(Self.memoryControl(2, 2))
        #expect(Array(player.rgb()[0..<3]) == [0, 0, 0x88])
        player.apply(Self.memoryControl(3, 3))
        #expect(Array(player.rgb()[0..<3]) == [0x88, 0, 0x88])
        // In the 2-plane state a scroll moves only the memories it works on: the SECONDARY's
        // picture moves, and the PRIMARY's stays where it is.
        player.apply(Self.memoryControl(3, 2))
        player.apply(Self.pack(24, [0, 0x03, 0x05]))
        #expect(player.secondaryHorizontalOffset == 3 && player.secondaryVerticalOffset == 5)
        #expect(player.horizontalOffset == 0 && player.verticalOffset == 0)
        // DM 00 with WM 01: no operation.
        player.apply(Self.memoryControl(0, 1))
        #expect(player.displayMode == 3)
    }

    /// The border shows its color, not the tiles under it, which a scroll can fill with the
    /// picture (the IA's CD+EG videos of *Mashin Hero Wataru 3* show it plain).
    @Test func showsTheBorderInItsColor() {
        var screen = CDGraphicsScreen()
        screen.apply(Self.pack(30, [0, 0, 0x3C, 0, 0x03, 0x30]))  // 0 black, 1 red, 2 green
        screen.apply(Self.pack(1, [0, 0]))
        screen.apply(Self.pack(2, [1]))
        // A tile in the ring, at row 0 and column 0, all green.
        screen.apply(Self.pack(6, [2, 2, 0, 0] + [UInt8](repeating: 0x3F, count: 12)))
        #expect(screen.pixels[0] == 2 && Array(screen.rgb()[0..<3]) == [255, 0, 0])
    }

    /// One video for the disc, a chapter for each track at its start, and the audio as ripped.
    @Test func writesAVideoWithChapters() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let graphics = folder.appending(path: "Track 01.cdg")
        let packs =
            [Self.pack(30, [0, 0, 0x3C, 0]), Self.pack(1, [1, 0])]
            + Array(repeating: [UInt8](repeating: 0, count: 24), count: 598)
        try Data(packs.joined()).write(to: graphics)
        var generator = SplitMix64(state: 3)
        let audio = (0..<(225 * CDDA.samplesPerSector)).map { _ in UInt32.random(in: .min ... .max, using: &generator) }
        let first = Array(audio[..<(150 * CDDA.samplesPerSector)])
        let second = Array(audio[(150 * CDDA.samplesPerSector)...])
        let chapters = [
            CDGraphicsVideo.Chapter(title: "What's on Your Mind", graphics: graphics, sectors: 150) { first },
            CDGraphicsVideo.Chapter(title: "Running", graphics: nil, sectors: 75) { second },
        ]
        let url = folder.appending(path: "Disc.m4v")
        var video = CDGraphicsVideo()
        video.scale = 2
        try video.write(chapters, to: url)

        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.duration) == CMTime(value: 3, timescale: 1))
        let locales = try await asset.load(.availableChapterLocales)
        let groups = try await asset.loadChapterMetadataGroups(
            withTitleLocale: locales.first ?? Locale(identifier: "en"), containingItemsWithCommonKeys: [])
        var titles = [String]()
        for group in groups { titles.append(try await group.items.first?.load(.stringValue) ?? "") }
        #expect(titles == ["What's on Your Mind", "Running"])
        #expect(groups.map(\.timeRange.start.seconds) == [0, 2])
        let size = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)
        #expect(size == CGSize(width: 600, height: 432))

        // The audio decodes to the samples, every one.
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
        reader.add(output)
        reader.startReading()
        var decoded = Data()
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var chunk = Data(count: CMBlockBufferGetDataLength(block))
            chunk.withUnsafeMutableBytes {
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            decoded.append(chunk)
        }
        let expected = audio.withUnsafeBytes { Data($0) }
        #expect(decoded == expected)
    }

    /// A rip's video goes into its album folder, named after the album, with AAC audio when
    /// asked; the reports record it, and an update of the library renames it with the album.
    @Test func putsTheVideoInTheAlbumFolder() async throws {
        let (folder, library) = try EncodingTests().makeRip()
        let root = folder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let packs = [Self.pack(30, [0, 0, 0x3C, 0]), Self.pack(1, [1, 0])]
        try Data(packs.joined()).write(to: folder.appending(path: "Track 01.cdg"))
        try RipReport.update(reportAt: folder.appending(path: "disc.json")) {
            $0.tracks[0].graphics = .init(file: "Track 01.cdg")
        }
        let (files, record) = try DiscEncoder(format: .flac).encodeWithRecord(
            try RippedDisc(folder: folder), into: library)
        // As a rip records its encoding.
        try #require(record).save(inReportAt: folder.appending(path: "disc.json"))
        let album = files[0].deletingLastPathComponent()

        var video = CDGraphicsVideo()
        video.scale = 1
        video.audio = .aac
        let url = try video.write(try RippedDisc(folder: folder))
        let name = "Saint of Circumstance- Giants Stadium · East Rutherford · NJ · 6-17-91 (Disc 2).m4v"
        #expect(url == album.appending(path: name))
        let albumReport = album.appending(path: "Rip Report (Disc 2).json")
        #expect(try RipReport.read(from: albumReport).encoding?.videos == [.init(file: name, picture: .extended)])
        #expect(
            try RipReport.read(from: folder.appending(path: "disc.json")).encoding?.videos == [
                .init(file: name, picture: .extended)
            ])
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC)
        let title = try await AVMetadataItem.metadataItems(
            from: try await asset.load(.commonMetadata), filteredByIdentifier: .commonIdentifierTitle
        ).first?.load(.stringValue)
        #expect(title?.hasPrefix("Saint of Circumstance") == true)

        // The album renamed: the video follows it into the new folder, by the new name.
        try MetadataEdits(album: "Renamed").save(inDiscJSONOf: folder)
        let update = try DiscEncoder(format: .flac).updateLibrary(
            reportAt: folder.appending(path: "disc.json"), library: library,
            editsStore: ReleaseEditsStore(url: root.appending(path: "edits.json")))
        let renamed = try #require(update.albumFolder).appending(path: "Renamed (Disc 2).m4v")
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(
            try RipReport.read(from: renamed.deletingLastPathComponent().appending(path: "Rip Report (Disc 2).json"))
                .encoding?.videos?.map(\.file) == ["Renamed (Disc 2).m4v"])
    }

    /// A CD+EG disc's 16-color video is a file of its own, beside the 256-color one.
    @Test func namesACDEGDiscsCDGPicture() throws {
        let (folder, library) = try EncodingTests().makeRip()
        let root = folder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(Self.extendedPack(6, [0, 2, 1, 1, 0b111000])).write(to: folder.appending(path: "Track 01.cdg"))
        try RipReport.update(reportAt: folder.appending(path: "disc.json")) {
            $0.tracks[0].graphics = .init(file: "Track 01.cdg", extended: true)
        }
        let (_, record) = try DiscEncoder(format: .flac).encodeWithRecord(try RippedDisc(folder: folder), into: library)
        try #require(record).save(inReportAt: folder.appending(path: "disc.json"))
        #expect(CDGraphicsVideo.hasExtendedGraphics(try RipReport.read(from: folder.appending(path: "disc.json"))))
        var video = CDGraphicsVideo()
        video.scale = 1
        let urls = try CDGraphicsVideo.Pictures.both.pictures.map {
            video.picture = $0
            return try video.write(try RippedDisc(folder: folder))
        }
        #expect(urls[1].lastPathComponent.hasSuffix("(Disc 2) (CD+G).m4v"))
        let videos = try RipReport.read(from: folder.appending(path: "disc.json")).encoding?.videos
        #expect(
            videos?.map(\.picture) == [.extended, .standard] && videos?.map(\.file) == urls.map(\.lastPathComponent))
    }

    /// A rip that was not encoded keeps its video in its own folder.
    @Test func putsTheVideoBesideARipThatWasNotEncoded() throws {
        let (folder, _) = try EncodingTests().makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try Data(Self.pack(1, [1, 0])).write(to: folder.appending(path: "Track 02.cdg"))
        try RipReport.update(reportAt: folder.appending(path: "disc.json")) {
            $0.tracks[1].graphics = .init(file: "Track 02.cdg")
        }
        var video = CDGraphicsVideo()
        video.scale = 1
        let url = try video.write(try RippedDisc(folder: folder))
        #expect(url.deletingLastPathComponent().path == folder.path, "\(url.path)")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// A rip that was not verified gets its videos beside it; when it is accepted and encoded,
    /// they move into the album folder, and the album's report records them, so the rip's
    /// folder can go with its WAV files.
    @Test func movesARipsVideosIntoItsAlbumWhenEncoded() throws {
        let (folder, library) = try EncodingTests().makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try Data(Self.extendedPack(6, [0, 2, 1, 1, 0b111000])).write(to: folder.appending(path: "Track 01.cdg"))
        try RipReport.update(reportAt: folder.appending(path: "disc.json")) {
            $0.tracks[0].graphics = .init(file: "Track 01.cdg", extended: true)
        }
        var video = CDGraphicsVideo()
        video.scale = 1
        let made = try CDGraphicsVideo.Pictures.both.pictures.map {
            video.picture = $0
            return try video.write(try RippedDisc(folder: folder))
        }
        #expect(made.allSatisfy { $0.deletingLastPathComponent().path == folder.path })

        let disc = try RippedDisc(folder: folder)
        let (_, record) = try DiscEncoder(format: .flac).encodeWithRecord(disc, into: library)
        let album = URL(filePath: try #require(record).folder)
        #expect(made.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let names = made.map(\.lastPathComponent)
        #expect(names.allSatisfy { FileManager.default.fileExists(atPath: album.appending(path: $0).path) })
        let expected: [RipReport.Encoding.Video] = [
            .init(file: names[0], picture: .extended), .init(file: names[1], picture: .standard),
        ]
        #expect(record?.videos == expected)
        #expect(
            try RipReport.read(from: album.appending(path: "Rip Report (Disc 2).json")).encoding?.videos == expected)
        // Nothing of them is left in the rip's folder, which can go with the WAV files.
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!left.contains { $0.hasSuffix(".m4v") }, "\(left)")
    }

    /// A rip's album folder that now holds another edition's album keeps its video: the rip's
    /// goes beside the rip (review of 6d31199).
    @Test func leavesAnotherEditionsVideoAlone() throws {
        let (folder, library) = try EncodingTests().makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try Data(Self.pack(1, [1, 0])).write(to: folder.appending(path: "Track 01.cdg"))
        try RipReport.update(reportAt: folder.appending(path: "disc.json")) {
            $0.tracks[0].graphics = .init(file: "Track 01.cdg")
        }
        let (_, record) = try DiscEncoder(format: .flac).encodeWithRecord(try RippedDisc(folder: folder), into: library)
        try #require(record).save(inReportAt: folder.appending(path: "disc.json"))
        let disc = try RippedDisc(folder: folder)
        let album = URL(filePath: try #require(record).folder)
        let name = CDGraphicsVideo.fileName(release: disc.release, toc: disc.toc)
        let other = album.appending(path: name)
        let sentinel = Data("another edition's video".utf8)
        try sentinel.write(to: other)
        try RipReport.update(reportAt: album.appending(path: "Rip Report (Disc 2).json")) {
            $0.release?.id = "another-release"
            $0.encoding?.videos = [.init(file: name, picture: .extended)]
        }
        var video = CDGraphicsVideo()
        video.scale = 1
        let url = try video.write(disc)
        #expect(try Data(contentsOf: other) == sentinel)
        #expect(url.deletingLastPathComponent().path == folder.path)
    }
}
