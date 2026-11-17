import Foundation
import Testing

@testable import SilversideKit

struct MusicAddTests {
    func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func settings(library: URL, copies: URL) -> Settings {
        var settings = Settings()
        settings.library = library.path
        settings.musicCopies = copies.path
        return settings
    }

    /// What the scripts print: each added track's ID and file (none when Music gave none), and
    /// the tracks that look like the album, each once, with those of an earlier add still there.
    @Test func readsMusicsAnswers() {
        let tracks = MusicApp.tracks(in: "ABC123\t/Users/me/Music/Media/01 One.m4a\nDEF456\t\n\t/x")
        #expect(
            tracks == [
                MusicApp.Track(persistentID: "ABC123", location: URL(filePath: "/Users/me/Music/Media/01 One.m4a")),
                MusicApp.Track(persistentID: "DEF456"),
            ])
        let found = MusicApp.found(
            in: "album\tA1\tAbbey Road\nalbum\tA2\tAbbey Road (Remastered)\nalbum\tA1\tAbbey Road\nadded\tA1\nother")
        #expect(found.tracks.map(\.persistentID) == ["A1", "A2"])
        #expect(found.tracks.map(\.album) == ["Abbey Road", "Abbey Road (Remastered)"])
        #expect(found.addedBefore == 1)
        #expect(MusicApp.found(in: "").isEmpty)
    }

    /// Music has the album itself when it has tracks of the very title, or the tracks that
    /// Silverside gave it; an edition whose title says more only looks like it.
    @Test func tellsTheAlbumFromAnotherEdition() {
        let album = MusicApp.Album(title: "Abbey Road", artist: "The Beatles")
        let other = MusicApp.Found(tracks: [MusicApp.Track(persistentID: "A", album: "Abbey Road (Remastered)")])
        #expect(!other.hasAlbum(album))
        #expect(other.description(of: album) == "Music has 1 track of “Abbey Road (Remastered)” by The Beatles.")
        let same = MusicApp.Found(tracks: ["B", "C"].map { MusicApp.Track(persistentID: $0, album: "abbey road") })
        #expect(same.hasAlbum(album))
        #expect(MusicApp.Found(addedBefore: 17).hasAlbum(album))
        #expect(MusicApp.Found().description(of: album) == nil)
        let disc = MusicApp.Album(title: "1967-1970", artist: "The Beatles", disc: 2)
        let added = MusicApp.Found(tracks: [MusicApp.Track(persistentID: "D", album: "1967-1970")], addedBefore: 2)
        #expect(
            added.description(of: disc)
                == "Music has 2 tracks of “1967-1970” by The Beatles (disc 2), which Silverside added.")
    }

    /// The album to look for is the first file's: its album artist, else its artist; its disc
    /// only in a set of more than one; and the tracks of an earlier add.
    @Test func namesTheAlbumFromTheTags() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let set = folder.appending(path: "set.flac")
        try AudioEncoder.encode(LibraryAlbumTests.twoSeconds, format: .flac, to: set)
        try FLACTags.write(
            [
                ("ALBUM", "1967-1970"), ("ALBUMARTIST", "The Beatles"), ("ARTIST", "Beatles"), ("DISCNUMBER", "2"),
                ("DISCTOTAL", "2"),
            ], cover: nil, to: set)
        let record = RipReport.Encoding.MusicRecord(date: Date(), format: .alac, tracks: ["A", "B"])
        #expect(
            MusicAdd.album(of: [set], record: record)
                == MusicApp.Album(title: "1967-1970", artist: "The Beatles", disc: 2, trackIDs: ["A", "B"]))
        let single = folder.appending(path: "single.flac")
        try AudioEncoder.encode(LibraryAlbumTests.twoSeconds, format: .flac, to: single)
        try FLACTags.write(
            [("ALBUM", "Abbey Road"), ("ARTIST", "The Beatles"), ("DISCNUMBER", "1/1")], cover: nil, to: single)
        #expect(MusicAdd.album(of: [single]) == MusicApp.Album(title: "Abbey Road", artist: "The Beatles"))
    }

    /// A FLAC file becomes an Apple Lossless copy with every bit, its tags, and its cover:
    /// 16-bit audio, the 20 bits of an HDCD decode, and the six channels of a DTS decode.
    @Test func copiesFLACAsAppleLosslessBitForBit() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cover = try EmbeddedCover(makeJPEG(width: 20, height: 20))
        let tags = [("TITLE", "Come Together"), ("ALBUM", "Abbey Road"), ("TRACKNUMBER", "1"), ("TRACKTOTAL", "17")]
        func flac(_ name: String, _ write: (URL) throws -> Void) throws -> URL {
            let url = folder.appending(path: name)
            try write(url)
            try FLACTags.write(tags, cover: cover, to: url)
            return url
        }

        let plain = try flac("plain.flac") {
            try AudioEncoder.encode(LibraryAlbumTests.twoSeconds, format: .flac, to: $0)
        }
        let plainCopy = folder.appending(path: "plain.m4a")
        try MusicAdd.convert(plain, to: plainCopy, format: .alac, aac: AACOptions())
        #expect(try AudioEncoder.decode(plainCopy) == LibraryAlbumTests.twoSeconds)
        let read = try MP4Tags.read(plainCopy)
        #expect(read.comments.first { $0.key == "TITLE" }?.value == "Come Together")
        #expect(read.comments.first { $0.key == "TRACKNUMBER" }?.value == "1")
        #expect(read.cover == cover.image.data)

        // Values of 20 bits, as an HDCD decode in FLAC has them: the low 12 of 32 are zero.
        let wide = LibraryAlbumTests.twoSeconds.flatMap { sample in
            [Int32(Int16(bitPattern: UInt16(sample & 0xFFFF))), Int32(Int16(bitPattern: UInt16(sample >> 16)))]
                .map { ($0 << 16) | (($0 & 0xF) << 12) }
        }
        let twenty = try flac("twenty.flac") { try AudioEncoder.encode(.wide(wide), format: .flac, to: $0) }
        let twentyCopy = folder.appending(path: "twenty.m4a")
        try MusicAdd.convert(twenty, to: twentyCopy, format: .alac, aac: AACOptions())
        #expect(try AudioEncoder.decodeWide(twentyCopy) == wide)
        #expect(AudioDetails.read(twentyCopy)?.format.bits == 20)

        let (surround, _) = SurroundLayoutTests.tones(mask: 0x3F)
        let six = try flac("six.flac") { try AudioEncoder.encode(surround, format: .flac, to: $0) }
        let sixCopy = folder.appending(path: "six.m4a")
        try MusicAdd.convert(six, to: sixCopy, format: .alac, aac: AACOptions())
        #expect(try AudioEncoder.decodeSurround(sixCopy, as: 0x3F)?.values == surround.values)
        // Nothing is left beside the copies.
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
                == ["plain.flac", "plain.m4a", "six.flac", "six.m4a", "twenty.flac", "twenty.m4a"])
    }

    /// An AAC copy has the track's length and its tags.
    @Test func copiesFLACAsAAC() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "a.flac")
        try AudioEncoder.encode(LibraryAlbumTests.twoSeconds, format: .flac, to: source)
        try FLACTags.write([("TITLE", "Something")], cover: nil, to: source)
        let copy = folder.appending(path: "a.m4a")
        try MusicAdd.convert(source, to: copy, format: .aac, aac: AACOptions())
        #expect(abs(try AudioEncoder.decode(copy).count - LibraryAlbumTests.twoSeconds.count) < 4 * 1152)
        #expect(AudioDetails.read(copy)?.format.name == "AAC")
        #expect(try MP4Tags.read(copy).comments.first { $0.key == "TITLE" }?.value == "Something")
    }

    /// The copies of an album take its place in the library, in their own folder; an album
    /// elsewhere goes by its folder's name. A folder for them in the library is refused.
    @Test func putsTheCopiesOutsideTheLibrary() throws {
        let library = URL(filePath: "/Music/Library", directoryHint: .isDirectory)
        let copies = URL(filePath: "/Music/For Music", directoryHint: .isDirectory)
        let music = MusicAdd(settings: settings(library: library, copies: copies))
        #expect(
            try music.copiesFolder(for: library.appending(path: "The Beatles/Abbey Road")).path
                == "/Music/For Music/The Beatles/Abbey Road")
        #expect(
            try music.copiesFolder(for: URL(filePath: "/Elsewhere/Abbey Road")).path == "/Music/For Music/Abbey Road")
        let inside = MusicAdd(settings: settings(library: library, copies: library.appending(path: "Copies")))
        #expect(throws: MusicAddError.self) { try inside.copiesFolder(for: library.appending(path: "A/B")) }
    }

    /// An add never replaces a file: a copy's name taken moves the copies to "Album 2", and a
    /// copy that fails takes the others away again. Through a symbolic link, the library and the
    /// album's own folder are still refused.
    @Test func neverPutsTheCopiesOverAFile() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let library = root.appending(path: "Library", directoryHint: .isDirectory)
        let copies = root.appending(path: "Copies", directoryHint: .isDirectory)
        let album = library.appending(path: "Artist/Album", directoryHint: .isDirectory)
        for folder in [album, copies] { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
        let flac = album.appending(path: "01 A.flac")
        try AudioEncoder.encode(LibraryAlbumTests.twoSeconds, format: .flac, to: flac)
        let notAudio = album.appending(path: "02 B.flac")
        try Data("not audio".utf8).write(to: notAudio)
        let music = MusicAdd(settings: settings(library: library, copies: copies))
        let first = copies.appending(path: "Artist/Album", directoryHint: .isDirectory)
        #expect(try music.copiesFolder(for: album, files: [flac]).path == first.path)

        // Someone else's file of a copy's name.
        try manager.createDirectory(at: first, withIntermediateDirectories: true)
        let theirs = first.appending(path: "01 A.m4a")
        try Data("theirs".utf8).write(to: theirs)
        let second = copies.appending(path: "Artist/Album 2", directoryHint: .isDirectory)
        #expect(try music.copiesFolder(for: album, files: [flac]).path == second.path)
        #expect(try music.copiesFolder(for: album, files: [notAudio]).path == first.path)
        #expect(throws: (any Error).self) { try music.copy([flac], into: first) }
        #expect(try Data(contentsOf: theirs) == Data("theirs".utf8))

        // A copy that fails: the one made goes, and so does its folder, but not other files.
        #expect(throws: (any Error).self) { try music.copy([flac, notAudio], into: second) }
        #expect(!manager.fileExists(atPath: second.path))
        let cover = first.appending(path: "cover.jpg")
        try Data("cover".utf8).write(to: cover)
        try manager.removeItem(at: theirs)
        #expect(throws: (any Error).self) { try music.copy([flac, notAudio], into: first) }
        #expect(try manager.contentsOfDirectory(atPath: first.path) == ["cover.jpg"])
        #expect(try music.copy([flac], into: first).map(\.lastPathComponent) == ["01 A.m4a"])

        // A link in the copies' folder that leads into the library.
        let linked = MusicAdd(settings: settings(library: library, copies: root.appending(path: "Linked")))
        try manager.createSymbolicLink(at: root.appending(path: "Linked"), withDestinationURL: library)
        #expect(throws: MusicAddError.copiesInLibrary(root.appending(path: "Linked", directoryHint: .isDirectory))) {
            try linked.copiesFolder(for: album)
        }
        try manager.createSymbolicLink(at: copies.appending(path: "Elsewhere"), withDestinationURL: library)
        #expect(throws: MusicAddError.self) {
            try music.copiesFolder(for: library.appending(path: "Elsewhere/Artist/Album"))
        }

        // An album outside the library, in the copies' own folder.
        let outside = root.appending(path: "Old/Album", directoryHint: .isDirectory)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let old = MusicAdd(settings: settings(library: library, copies: root.appending(path: "Old")))
        #expect(throws: MusicAddError.copiesInAlbum(outside)) { try old.copiesFolder(for: outside) }
    }

    /// Silverside's copies go only when Music has its own: a file for each copy, of the same
    /// sizes, none of them a copy. Then the empty folders go too, up to the copies' own.
    @Test func deletesTheCopiesOnlyWhenMusicCopiedThem() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let copies = root.appending(path: "For Music", directoryHint: .isDirectory)
        let album = copies.appending(path: "Artist/Album", directoryHint: .isDirectory)
        let theirs = root.appending(path: "Media", directoryHint: .isDirectory)
        for folder in [album, theirs] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let made = [album.appending(path: "01.m4a"), album.appending(path: "02.m4a")]
        let copied = [theirs.appending(path: "02 Two.m4a"), theirs.appending(path: "01 One.m4a")]
        try Data(count: 10).write(to: made[0])
        try Data(count: 20).write(to: made[1])
        try Data(count: 20).write(to: copied[0])
        try Data(count: 10).write(to: copied[1])
        let music = MusicAdd(settings: settings(library: root.appending(path: "Library"), copies: copies))

        // Music plays the copies, or did not say where its files are: they stay.
        let playsCopies = zip(["1", "2"], made).map { MusicApp.Track(persistentID: $0, location: $1) }
        #expect(music.removeCopies(made, addedAs: playsCopies) == 2)
        #expect(music.removeCopies(made, addedAs: []) == 2)
        #expect(
            music.removeCopies(made, addedAs: [MusicApp.Track(persistentID: "1"), MusicApp.Track(persistentID: "2")])
                == 2)
        // A file of another size may not be done yet.
        let short = [
            MusicApp.Track(persistentID: "1", location: copied[0]),
            MusicApp.Track(persistentID: "2", location: copied[0]),
        ]
        #expect(music.removeCopies(made, addedAs: short) == 2)
        #expect(made.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        let copiedTracks = zip(["1", "2"], copied).map { MusicApp.Track(persistentID: $0, location: $1) }
        #expect(music.removeCopies(made, addedAs: copiedTracks) == 0)
        #expect(!FileManager.default.fileExists(atPath: copies.appending(path: "Artist").path))
        #expect(FileManager.default.fileExists(atPath: copies.path))
        #expect(copied.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    /// The files come from the album's report, in the order of the tracks. An album that keeps
    /// a DTS stream cannot go, nor one whose files are gone.
    @Test func takesTheFilesFromTheReport() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (release, tocs) = try RipSetTests.cornell()
        var report = RipSetTests.report(release, toc: try #require(tocs[1]))
        report.encoding = RipReport.Encoding(
            format: .flac, encoder: "Apple AudioToolbox", folder: folder.path,
            files: [.init(track: 2, file: "02 B.flac"), .init(track: 1, file: "01 A.flac")])
        for name in ["01 A.flac", "02 B.flac"] { try Data().write(to: folder.appending(path: name)) }
        let (files, format) = try MusicAdd.files(of: report)
        #expect(files.map(\.lastPathComponent) == ["01 A.flac", "02 B.flac"])
        #expect(format == .flac)

        report.dts = .stream
        #expect(throws: MusicAddError.dtsStream) { try MusicAdd.files(of: report) }
        report.encoding?.dtsDecoded = "5.1"
        #expect(try MusicAdd.files(of: report).files.count == 2)

        try FileManager.default.removeItem(at: folder.appending(path: "02 B.flac"))
        #expect(throws: MusicAddError.missing(folder.appending(path: "02 B.flac"))) { try MusicAdd.files(of: report) }
        report.encoding = nil
        #expect(throws: MusicAddError.notEncoded) { try MusicAdd.files(of: report) }
    }

    /// An add is kept in the rip's disc.json and in its album folder's report, which keep every
    /// other key; a later read has it.
    @Test func keepsTheAddInBothReports() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let rip = root.appending(path: "rip", directoryHint: .isDirectory)
        let album = root.appending(path: "album", directoryHint: .isDirectory)
        for folder in [rip, album] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let (release, tocs) = try RipSetTests.cornell()
        var report = RipSetTests.report(release, toc: try #require(tocs[2]))
        report.encoding = RipReport.Encoding(
            format: .flac, encoder: "Apple AudioToolbox", folder: album.path, files: [.init(track: 1, file: "01.flac")])
        try report.write(to: rip.appending(path: "disc.json"))
        let albumReport = album.appending(path: "Rip Report (Disc 2).json")
        try report.write(to: albumReport)

        let record = RipReport.Encoding.MusicRecord(
            date: Date(timeIntervalSince1970: 1_800_000_000), format: .alac, tracks: ["A1", "A2"])
        try RipReport.Encoding.saveMusic(record, reportAt: rip.appending(path: "disc.json"))
        #expect(try RipReport.read(from: rip.appending(path: "disc.json")).encoding?.music == record)
        #expect(try RipReport.read(from: albumReport).encoding?.music == record)
        #expect(try RipReport.read(from: albumReport).encoding?.files == report.encoding?.files)
    }

    /// The settings: Apple Lossless copies in a folder of their own, unless the file says otherwise.
    @Test func readsTheMusicSettings() throws {
        let defaults = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(defaults.musicFormat == .alac)
        #expect(defaults.musicCopiesURL.path.hasSuffix("/Music/Silverside for Music"))
        let changed = try defaults.setting("musicFormat", to: "aac").setting("musicCopies", to: "/Volumes/Copies")
        #expect(MusicAdd(settings: changed).format == .aac)
        #expect(MusicAdd(settings: changed).copies.path == "/Volumes/Copies")
        // A format that is not one for copies gives Apple Lossless.
        #expect(MusicAdd(settings: try defaults.setting("musicFormat", to: "flac")).format == .alac)
    }
}
