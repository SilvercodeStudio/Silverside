import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import CDRipKit

/// A JPEG test image of the given size.
func makeJPEG(width: Int, height: Int) throws -> CoverImage {
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return CoverImage(data: data as Data)
}

struct TagWriterTests {
    static let comments: [(key: String, value: String)] = [
        ("TITLE", "Walkin' Blues [Merriweather Post Pavilion, 7-1-85]"), ("ARTIST", "Grateful Dead"),
        ("DISCNUMBER", "18"), ("DISCTOTAL", "20"), ("TRACKNUMBER", "3"), ("TRACKTOTAL", "8"),
        ("DISCSUBTITLE", "1985-07-01 Merriweather Post Pavilion, Columbia, MD"), ("ARTIST", "Second Artist"),
    ]

    func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "CDRipTests-\(UUID())-\(name)")
    }

    @Test func scalesALargeCoverAndKeepsASmallOne() throws {
        let large = try EmbeddedCover(try makeJPEG(width: 1600, height: 1200))
        #expect(large.width == 1000 && large.height == 750 && large.image.fileExtension == "jpg")
        let small = try makeJPEG(width: 500, height: 500)
        #expect(try EmbeddedCover(small).image == small)
    }

    @Test func writesFLACTagsAndKeepsTheAudio() throws {
        let url = temporaryFile("track.flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioEncoder.encode(AudioEncoderTests.samples, format: .flac, to: url)
        let cover = try EmbeddedCover(try makeJPEG(width: 1600, height: 1600))
        try FLACTags.write(Self.comments, cover: cover, to: url)
        #expect(try FLACTags.read(url).map { "\($0.key)=\($0.value)" } == Self.comments.map { "\($0.key)=\($0.value)" })
        #expect(try FLACTags.readFrontCover(url) == cover.image.data)
        #expect(try AudioEncoder.decode(url) == AudioEncoderTests.samples)
        // Writing again replaces the tags; it does not add to them.
        try FLACTags.write([("TITLE", "Again")], cover: nil, to: url)
        #expect(try FLACTags.read(url).map(\.value) == ["Again"])
        #expect(try FLACTags.readFrontCover(url) == nil)
        #expect(try AudioEncoder.decode(url) == AudioEncoderTests.samples)
    }

    func comparable(_ comments: [(key: String, value: String)]) -> [String] {
        comments.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// The freeform names in a file's ilst, such as "iTunSMPB".
    func freeformNames(_ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        let moov = try #require(try MP4Tags.atoms(in: data, 0..<data.count).first { $0.type == "moov" })
        return try MP4Tags.existingItems(in: data, moov: moov).compactMap { try MP4Tags.freeformName(of: $0, in: data) }
    }

    @Test func writesALACTagsAndMovesTheChunkOffsets() throws {
        let url = temporaryFile("track.m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioEncoder.encode(AudioEncoderTests.samples, format: .alac, to: url)
        let cover = try EmbeddedCover(try makeJPEG(width: 1000, height: 1000))
        let comments: [(key: String, value: String)] =
            Self.comments.filter { $0.key != "ARTIST" || $0.value == "Grateful Dead" } + [
                ("ALBUM", "Summer Magic 1985"), ("MUSICBRAINZ_ARTISTID", "a"), ("MUSICBRAINZ_ARTISTID", "b"),
            ]
        try MP4Tags.write(comments, cover: cover, to: url)
        let read = try MP4Tags.read(url)
        #expect(comparable(read.comments) == comparable(comments))
        #expect(read.cover == cover.image.data)
        // Every chunk offset moved with the audio, so the file still decodes to the rip.
        #expect(try AudioEncoder.decode(url) == AudioEncoderTests.samples)
        // Writing again replaces the tags.
        try MP4Tags.write([("TITLE", "Again")], cover: nil, to: url)
        #expect(try MP4Tags.read(url).comments.map(\.value) == ["Again"])
        #expect(try AudioEncoder.decode(url) == AudioEncoderTests.samples)
    }

    /// Tags must not change the audio, and must keep the encoder's gapless information.
    @Test func writesAACTagsAndKeepsTheEncodersItems() throws {
        let url = temporaryFile("track.m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioEncoder.encode(AudioEncoderTests.samples, format: .aac, to: url)
        let before = try AudioEncoder.decode(url)
        let encoderItems = try freeformNames(url)
        try MP4Tags.write(Self.comments, cover: try EmbeddedCover(try makeJPEG(width: 600, height: 600)), to: url)
        #expect(try AudioEncoder.decode(url) == before)
        #expect(Set(encoderItems).isSubset(of: Set(try freeformNames(url))))
        #expect(try MP4Tags.read(url).comments.contains { $0.key == "DISCSUBTITLE" })
    }
}

struct MP3Tests {
    @Test(.enabled(if: MP3Encoder.lame() != nil, "lame is not installed"))
    func encodesThroughLameAndTagsTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "CDRipTests-\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try MP3Encoder.encode(AudioEncoderTests.samples, to: url, lame: try #require(MP3Encoder.lame()))
        try ID3Tags.write(
            TagWriterTests.comments + [("ALBUM", "Summer Magic 1985"), ("MUSICBRAINZ_TRACKID", "rec")],
            cover: try EmbeddedCover(try makeJPEG(width: 600, height: 600)), to: url)
        let frames = try ID3Tags.readTextFrames(url)
        #expect(frames["TIT2"] == "Walkin' Blues [Merriweather Post Pavilion, 7-1-85]")
        #expect(frames["TPE1"] == "Grateful Dead\0Second Artist")
        #expect(frames["TRCK"] == "3/8" && frames["TPOS"] == "18/20")
        #expect(frames["TSST"] == "1985-07-01 Merriweather Post Pavilion, Columbia, MD")
        // MP3 adds a little silence at the ends, so the length is about the same, not equal.
        let decoded = try AudioEncoder.decode(url)
        #expect(abs(decoded.count - AudioEncoderTests.samples.count) < 4 * 1152)
        // A second write replaces the tag.
        try ID3Tags.write([("TITLE", "Again")], cover: nil, to: url)
        #expect(try ID3Tags.readTextFrames(url)["TIT2"] == "Again")
        #expect(abs(try AudioEncoder.decode(url).count - decoded.count) == 0)
    }
}
