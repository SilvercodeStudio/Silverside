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
}
