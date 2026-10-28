import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import SilversideKit

/// A JPEG test image of the given size.
func makeJPEG(width: Int, height: Int) throws -> CoverImage {
    try makeImage(width: width, height: height, type: .jpeg)
}

/// A test image of the given size and format.
func makeImage(width: Int, height: Int, type: UTType) throws -> CoverImage {
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil))
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
        FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())-\(name)")
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

struct ChunkTagsTests {
    /// Tags in AIFF and WAV must not change the audio, and a second write replaces them.
    @Test(arguments: [AudioFormat.aiff, .wav])
    func tagsAIFFAndWAV(format: AudioFormat) throws {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "SilversideTests-\(UUID()).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = Array(AudioEncoderTests.samples.prefix(44_101))
        if format == .aiff {
            try AudioEncoder.encode(samples, format: .aiff, to: url)
        } else {
            try WAVFile.write(samples, to: url)
        }
        let cover = try EmbeddedCover(try makeJPEG(width: 300, height: 300))
        for title in ["First", "Second"] {
            let comments: [(key: String, value: String)] = [
                ("TITLE", title), ("ARTIST", "Grateful Dead"), ("TRACKNUMBER", "3"),
            ]
            if format == .aiff {
                try ChunkTags.writeAIFF(comments, cover: cover, to: url)
            } else {
                try ChunkTags.writeWAV(comments, cover: cover, to: url)
            }
        }
        #expect(try AudioEncoder.decode(url) == samples)
        if format == .wav { #expect(try WAVFile.read(url) == samples) }
        let bytes = [UInt8](try Data(contentsOf: url))
        let id3 = format == .aiff ? "ID3 " : "id3 "
        // One tag chunk, with the second title only.
        #expect(bytes.indices.filter { bytes[$0...].starts(with: Array(id3.utf8)) }.count == 1)
        #expect(
            String(decoding: bytes, as: UTF8.self).contains("Second")
                && !String(decoding: bytes, as: UTF8.self).contains("First"))
        // The form's size is the file's size less 8.
        let size =
            format == .aiff
            ? (4..<8).reduce(0) { $0 << 8 | Int(bytes[$1]) } : (4..<8).reversed().reduce(0) { $0 << 8 | Int(bytes[$1]) }
        #expect(size == bytes.count - 8)
    }
}

/// Files that are cut short, or hold atoms and frames that are too small: the readers must
/// throw or skip them, not stop the process.
struct MalformedTagTests {
    func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())-\(name)")
    }

    @Test func flacPictureBlockThatIsTooShort() throws {
        let url = temporaryFile("short.flac")
        defer { try? FileManager.default.removeItem(at: url) }
        // STREAMINFO, then a last PICTURE block whose MIME type length runs past its end.
        var file = Data("fLaC".utf8) + Data([0, 0, 0, 34]) + Data(count: 34)
        let picture = Data([0, 0, 0, 3, 0, 0, 1, 0]) + Data("image/jpeg".utf8)
        file += Data([0x86, 0, 0, UInt8(picture.count)]) + picture
        try file.write(to: url)
        #expect(throws: FLACError.malformed) { try FLACTags.readFrontCover(url) }
        #expect(try FLACTags.read(url).isEmpty)
    }

    @Test func mp4ItemsThatAreTooSmall() throws {
        let url = temporaryFile("short.m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        // A title whose data atom has no type and locale, and a freeform item whose name has no flags.
        let ilst = MP4Tags.atom(
            "ilst",
            [
                MP4Tags.atom("©nam", [MP4Tags.atom("data", [Data([1, 2, 3])])]),
                MP4Tags.atom("----", [MP4Tags.atom("name", [Data([1])])]),
                MP4Tags.atom("©alb", [MP4Tags.dataAtom(1, Data("Album".utf8))]),
            ])
        let moov = MP4Tags.atom("moov", [MP4Tags.atom("udta", [MP4Tags.meta(ilst)])])
        try (MP4Tags.atom("ftyp", []) + moov + MP4Tags.atom("mdat", [])).write(to: url)
        let read = try MP4Tags.read(url)
        #expect(read.comments.map { "\($0.key)=\($0.value)" } == ["ALBUM=Album"])
        // A meta atom with no version and flags.
        let bare = MP4Tags.atom("moov", [MP4Tags.atom("udta", [MP4Tags.atom("meta", [Data([0])])])])
        try (MP4Tags.atom("ftyp", []) + bare + MP4Tags.atom("mdat", [])).write(to: url)
        #expect(throws: MP4Error.malformed) { try MP4Tags.read(url) }
    }

    @Test func id3FrameThatRunsPastTheTag() throws {
        let url = temporaryFile("short.mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        let frame = Data("TIT2".utf8) + ID3Tags.syncsafe(1000) + Data([0, 0, 3]) + Data("x".utf8)
        try (Data("ID3".utf8) + Data([4, 0, 0]) + ID3Tags.syncsafe(frame.count) + frame).write(to: url)
        #expect(throws: MP3Error.malformedID3Tag(url)) { try ID3Tags.readTextFrames(url) }
        // A tag that claims more bytes than the file has.
        try (Data("ID3".utf8) + Data([4, 0, 0]) + ID3Tags.syncsafe(5000) + frame).write(to: url)
        #expect(throws: MP3Error.malformedID3Tag(url)) { try ID3Tags.readTextFrames(url) }
    }

    /// An encoder that exits without reading its input: the writes fail, and the failure is
    /// reported, in place of SIGPIPE ending the process.
    @Test func reportsAnEncoderThatStopsReading() throws {
        let url = temporaryFile("none.mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: MP3Error.self) {
            try MP3Encoder.encode(AudioEncoderTests.samples, to: url, lame: URL(filePath: "/usr/bin/false"))
        }
    }
}

struct MP3Tests {
    @Test(.enabled(if: MP3Encoder.lame() != nil, "lame is not installed"))
    func encodesThroughLameAndTagsTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID()).mp3")
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
