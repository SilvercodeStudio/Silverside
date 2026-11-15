import Foundation
import Testing

@testable import SilversideKit

/// `silverside tags`: what Silverside reads of any audio file, and the summary of a folder.
struct TagSummaryTests {
    func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// An ID3v2.3 frame: its ID, a plain 32-bit size, no flags, and its body.
    func frame(_ id: String, _ body: [UInt8]) -> [UInt8] {
        let size = body.count
        return Array(id.utf8) + [
            UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF), 0, 0,
        ]
            + body
    }

    func utf16(_ text: String) -> [UInt8] {
        [0xFF, 0xFE] + text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }

    /// An ID3v2.3 tag as other programs write it: ISO-8859-1 and UTF-16 text, TYER, a TXXX that
    /// Silverside knows and one it does not, a comment, a track number with its total, and a cover.
    @Test func readsAnID3v23Tag() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cover = try makeJPEG(width: 50, height: 50).data
        var frames = [UInt8]()
        frames += frame("TIT2", [0] + Array("Caf\u{E9} Blues".unicodeScalars.map { UInt8($0.value) }))
        frames += frame("TPE1", [1] + utf16("Coleman Hawkins") + [0, 0])
        frames += frame("TPE2", [0] + Array("Coleman Hawkins".utf8))
        frames += frame("TYER", [0] + Array("1996".utf8))
        frames += frame("TRCK", [0] + Array("4/12".utf8))
        frames += frame("TPOS", [0] + Array("1/2".utf8))
        frames += frame("TXXX", [1] + utf16("MusicBrainz Album Id") + [0, 0] + utf16("abc") + [0, 0])
        frames += frame("TXXX", [0] + Array("Source".utf8) + [0] + Array("Vinyl".utf8))
        frames += frame("COMM", [0] + Array("eng".utf8) + [0] + Array("Ripped by me".utf8))
        frames += frame("APIC", [0] + Array("image/jpeg".utf8) + [0, 3] + [0] + Array(cover))
        let size = frames.count
        let header: [UInt8] =
            Array("ID3".utf8) + [3, 0, 0]
            + [UInt8(size >> 21 & 0x7F), UInt8(size >> 14 & 0x7F), UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F)]
        let url = folder.appending(path: "01.mp3")
        try Data(header + frames + [0xFF, 0xFB, 0x90, 0x00]).write(to: url)

        let read = try #require(try ID3Tags.read(url))
        #expect(
            read.comments.map { "\($0.key)=\($0.value)" } == [
                "TITLE=Caf\u{E9} Blues", "ARTIST=Coleman Hawkins", "ALBUMARTIST=Coleman Hawkins", "DATE=1996",
                "TRACKNUMBER=4", "TRACKTOTAL=12", "DISCNUMBER=1", "DISCTOTAL=2", "MUSICBRAINZ_ALBUMID=abc",
                "SOURCE=Vinyl", "COMMENT=Ripped by me",
            ])
        #expect(read.cover == cover)
        // A tag that Silverside writes reads back the same.
        let written = folder.appending(path: "02.mp3")
        try Data([0xFF, 0xFB, 0x90, 0x00]).write(to: written)
        try ID3Tags.write(
            [("TITLE", "Body and Soul"), ("TRACKNUMBER", "4"), ("TRACKTOTAL", "12"), ("BARCODE", "0123")],
            cover: nil, to: written)
        let again = try #require(try ID3Tags.read(written))
        #expect(again.comments.contains { $0 == ("TITLE", "Body and Soul") })
        #expect(
            again.comments.contains { $0 == ("TRACKTOTAL", "12") }
                && again.comments.contains { $0 == ("BARCODE", "0123") })
    }

    @Test func readsEveryItemOfAnMP4File() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "01.m4a")
        try AudioEncoder.encode(LibraryAlbumTests.twoSeconds, format: .alac, to: url)
        try MP4Tags.write([("TITLE", "Come Together")], cover: nil, to: url)
        var data = try Data(contentsOf: url)
        let top = try MP4Tags.atoms(in: data, data.startIndex..<data.endIndex)
        let moov = top.first { $0.type == "moov" }!
        let items = try MP4Tags.existingItems(in: data, moov: moov).map { Data(data[$0.range]) }
        let mean = MP4Tags.atom("mean", [Data(count: 4) + Data("com.apple.iTunes".utf8)])
        let name = MP4Tags.atom("name", [Data(count: 4) + Data("iTunSMPB".utf8)])
        let extra = [
            MP4Tags.atom("©cmt", [MP4Tags.dataAtom(1, Data("from iTunes".utf8))]),
            MP4Tags.atom("cpil", [MP4Tags.dataAtom(21, Data([1]))]),
            MP4Tags.atom("----", [mean, name, MP4Tags.dataAtom(1, Data(" 00000000".utf8))]),
        ]
        data = try MP4Tags.rewritten(
            data, top: top, moov: moov, mdat: top.first { $0.type == "mdat" }!,
            ilst: MP4Tags.atom("ilst", items + extra))
        try data.write(to: url)
        #expect(try MP4Tags.read(url).comments.map(\.key) == ["TITLE"])
        let every = try MP4Tags.read(url, every: true).comments.map { "\($0.key)=\($0.value)" }
        #expect(every.contains("COMMENT=from iTunes") && every.contains("COMPILATION=1"))
        #expect(every.contains("iTunSMPB= 00000000") && every.contains("TITLE=Come Together"))

        // The summary leaves iTunes's gapless data out unless asked.
        let album = LibraryAlbum.read([url], in: folder)
        #expect(album.files[0].format?.name == "ALAC" && album.files[0].format?.bits == 16)
        let summary = album.tagSummary()
        #expect(summary.hidden.map(\.key) == ["iTunSMPB"] && !summary.files[0].contains { $0.key == "iTunSMPB" })
        #expect(album.tagSummary(technical: true).files[0].contains { $0.key == "iTunSMPB" })
    }

    /// The tags every file has with the same values are shown once; keys differ in case between
    /// programs ("Album", "ALBUM"), and count as one.
    @Test func summarizesTheTagsOfAFolder() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tags: [[(key: String, value: String)]] = [
            [("Album", "GRRR!"), ("TITLE", "Come On"), ("TRACKNUMBER", "1"), ("COMPOSER", "Chuck Berry")],
            [("ALBUM", "GRRR!"), ("TITLE", "Not Fade Away"), ("TRACKNUMBER", "2")],
        ]
        for (index, list) in tags.enumerated() {
            let url = folder.appending(path: "0\(index + 1).flac")
            try AudioEncoder.encode(LibraryAlbumTests.twoSeconds, format: .flac, to: url)
            try FLACTags.write(list, cover: nil, to: url)
        }
        let album = try LibraryAlbum.read(folder)
        #expect(
            album.files.map(\.format?.summary) == [
                "FLAC, 44.1 kHz, 16 bits, stereo", "FLAC, 44.1 kHz, 16 bits, stereo",
            ])
        #expect(album.files.allSatisfy { $0.bytes > 0 })
        let summary = album.tagSummary()
        #expect(summary.shared == [.init(key: "Album", values: ["GRRR!"])])
        #expect(summary.files[0].map(\.key) == ["TITLE", "TRACKNUMBER", "COMPOSER"])
        #expect(summary.files[1].map(\.values) == [["Not Fade Away"], ["2"]])

        // A folder with albums in folders of its own: each one that has audio files.
        let inner = folder.appending(path: "Disc 2")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try AudioEncoder.encode(LibraryAlbumTests.twoSeconds, format: .flac, to: inner.appending(path: "01.flac"))
        try FileManager.default.createDirectory(
            at: folder.appending(path: "Artwork"), withIntermediateDirectories: true)
        #expect(
            LibraryAlbum.audioFolders(under: folder).map(\.lastPathComponent) == [folder.lastPathComponent, "Disc 2"])
    }

    @Test func describesAFormat() {
        let lossy = LibraryAlbum.Format(name: "AAC", sampleRate: 44_100, channels: 2, bits: nil, bitRate: 256_000)
        #expect(lossy.summary == "AAC, 44.1 kHz, 256 kb/s, stereo")
        let wide = LibraryAlbum.Format(name: "FLAC", sampleRate: 88_200, channels: 6, bits: 24, bitRate: nil)
        #expect(wide.summary == "FLAC, 88.2 kHz, 24 bits, 6 channels")
    }
}
