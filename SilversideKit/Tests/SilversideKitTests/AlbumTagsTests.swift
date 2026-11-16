import Foundation
import Testing

@testable import SilversideKit

/// `silverside album`'s tags: the release's, merged over each file's own.
struct AlbumTagsTests {
    static func text(_ tags: [(key: String, value: String)]) -> [String] { tags.map { "\($0.key)=\($0.value)" } }

    /// Silverside's keys replace the file's, whatever their case, with every value; other
    /// programs' names for them go; a key with no value here keeps the file's; others stay.
    @Test func mergesTheReleasesTagsOverTheFilesOwn() {
        let existing: [(key: String, value: String)] = [
            ("album", "They Want My Soul (180g Clear Vinyl)"), ("Genre", "Indie"), ("COMPOSER", "Old A"),
            ("COMPOSER", "Old B"), ("TOTALTRACKS", "10"), ("Comment", "ANTI- 7377-1"), ("TRACKNUMBER", "1/10"),
            ("releasetype", "album"),
        ]
        let written: [(key: String, value: String)] = [
            ("ALBUM", "They Want My Soul"), ("TRACKNUMBER", "1"), ("TRACKTOTAL", "10"), ("COMPOSER", "Britt Daniel"),
        ]
        let merged = TagMerge.merged(existing, writing: written, otherRelease: false)
        #expect(
            Self.text(merged) == [
                "ALBUM=They Want My Soul", "TRACKNUMBER=1", "TRACKTOTAL=10", "COMPOSER=Britt Daniel", "Genre=Indie",
                "Comment=ANTI- 7377-1", "releasetype=album",
            ])
        let changes = TagMerge.changes(from: existing, to: merged)
        #expect(changes.map(\.key) == ["ALBUM", "TRACKNUMBER", "TRACKTOTAL", "COMPOSER"])
        #expect(changes[0].oldNames == ["album"] && changes[0].old == ["They Want My Soul (180g Clear Vinyl)"])
        #expect(changes[1].old == ["1/10"] && changes[1].new == ["1"])
        #expect(changes[2].isRenamedOnly && changes[2].oldNames == ["TOTALTRACKS"])
        #expect(changes[3].old == ["Old A", "Old B"] && changes[3].new == ["Britt Daniel"])
        // TOTALTRACKS became TRACKTOTAL with the same value: a new name only.
        let renamed = TagMerge.changes(from: [("TOTALTRACKS", "10")], to: [("TRACKTOTAL", "10")])
        #expect(renamed.count == 1 && renamed[0].isRenamedOnly && renamed[0].oldNames == ["TOTALTRACKS"])

        // A file tagged for another release loses that release's own tags.
        let picard: [(key: String, value: String)] = [
            ("MUSICBRAINZ_ALBUMID", "old"), ("RELEASETYPE", "album"), ("BARCODE", "123"), ("COMMENT", "kept"),
        ]
        let other = TagMerge.merged(picard, writing: [("MUSICBRAINZ_ALBUMID", "new")], otherRelease: true)
        #expect(Self.text(other) == ["MUSICBRAINZ_ALBUMID=new", "COMMENT=kept"])
        #expect(TagMerge.changes(from: picard, to: other).filter(\.isRemoved).map(\.key) == ["RELEASETYPE", "BARCODE"])
    }

    @Test func writesTheMergeIntoAFLACFile() throws {
        let folder = try LibraryAlbumTests().temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "01.flac")
        try LibraryAlbumTests().otherProgramsFLAC(at: url)
        let data = try Data(contentsOf: url)
        let after = try FLACTags.updating(data, comments: [("TITLE", "Come Together"), ("CUSTOM", "kept")], cover: nil)
        #expect(try AudioPayload.fingerprint(of: after, kind: .flac) == AudioPayload.fingerprint(of: data, kind: .flac))
        try after.write(to: url)
        #expect(Self.text(try FLACTags.read(url)) == ["TITLE=Come Together", "CUSTOM=kept"])
        // The vendor and both pictures stay.
        let (blocks, _) = try FLACTags.parseBlocks(after)
        #expect(try FLACTags.vendor(of: blocks.first { $0.type == 4 }!.body) == "reference libFLAC 1.4.3")
        #expect(try blocks.filter { $0.type == 6 }.map { try FLACTags.pictureType($0.body) }.sorted() == [3, 4])
    }

    @Test func writesTheMergeIntoAnMP4File() throws {
        let folder = try LibraryAlbumTests().temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "01.m4a")
        try AudioEncoder.encode(LibraryAlbumTests.twoSeconds, format: .alac, to: url)
        try MP4Tags.write([("TITLE", "Old"), ("TRACKNUMBER", "1"), ("TRACKTOTAL", "0")], cover: nil, to: url)
        var data = try Data(contentsOf: url)
        let top = try MP4Tags.atoms(in: data, data.startIndex..<data.endIndex)
        let moov = top.first { $0.type == "moov" }!
        // iTunes's own items: a comment, and the encoder that ©too names.
        let items = try MP4Tags.existingItems(in: data, moov: moov).filter { $0.type != "©too" }
            .map { Data(data[$0.range]) }
        let extra = [
            MP4Tags.atom("©cmt", [MP4Tags.dataAtom(1, Data("from iTunes".utf8))]),
            MP4Tags.atom("©too", [MP4Tags.dataAtom(1, Data("iTunes 12".utf8))]),
        ]
        data = try MP4Tags.rewritten(
            data, top: top, moov: moov, mdat: top.first { $0.type == "mdat" }!,
            ilst: MP4Tags.atom("ilst", items + extra))
        let written: [(key: String, value: String)] = [
            ("TITLE", "Come Together"), ("TRACKNUMBER", "1"), ("TRACKTOTAL", "17"), ("COMPILATION", "1"),
            ("MUSICBRAINZ_ALBUMID", "abc"),
        ]
        let after = try MP4Tags.updating(
            data, removing: TagMerge.removed(writing: written, otherRelease: false), adding: written, cover: nil)
        #expect(try AudioPayload.fingerprint(of: after, kind: .mp4) == AudioPayload.fingerprint(of: data, kind: .mp4))
        try after.write(to: url)
        let read = Self.text(try MP4Tags.read(url, every: true).comments)
        #expect(read.contains("TITLE=Come Together") && !read.contains("TITLE=Old"))
        #expect(read.contains("TRACKTOTAL=17") && read.contains("MUSICBRAINZ_ALBUMID=abc"))
        // iTunes's items stay; the encoder is still iTunes; the compilation is in cpil.
        #expect(
            read.contains("COMMENT=from iTunes") && read.contains("ENCODER=iTunes 12") && read.contains("COMPILATION=1")
        )
        #expect(read.filter { $0.hasPrefix("ENCODER=") }.count == 1)
        let newTop = try MP4Tags.atoms(in: after, after.startIndex..<after.endIndex)
        let types = try MP4Tags.existingItems(in: after, moov: newTop.first { $0.type == "moov" }!).map(\.type)
        #expect(types.contains("cpil") && types.filter { $0 == "trkn" }.count == 1)
        #expect(try AudioEncoder.decode(url) == LibraryAlbumTests.twoSeconds)
    }

    /// Files of two discs pair with the release's tracks over both; the album's changes show
    /// once; writing the tags with the cover makes one file of each, and a second run changes nothing.
    @Test func plansAndWritesTheTagsOfASet() async throws {
        let folder = try LibraryAlbumTests().temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (index, samples) in [LibraryAlbumTests.twoSeconds, LibraryAlbumTests.threeSeconds].enumerated() {
            let url = folder.appending(path: "0\(index + 1).flac")
            try AudioEncoder.encode(samples, format: .flac, to: url)
            try FLACTags.write(
                [
                    ("DISCNUMBER", "\(index + 1)"), ("TRACKNUMBER", "1"), ("title", "Song \(index + 1)"),
                    ("COMMENT", "mine"),
                ],
                cover: nil, to: url)
        }
        let album = try LibraryAlbum.read(folder)
        let release = LibraryAlbumTests.release([[2000], [3000]])
        let fit = try #require(release.fit(lengths: album.lengths))
        #expect(fit.media == [1, 2])
        var settings = Settings()
        settings.liveShowStyle = false
        let tags = AlbumTagsPlan.make(album: album, release: release, fit: fit, settings: settings)
        #expect(tags.files.map(\.medium.position) == [1, 2] && tags.hasChanges)
        #expect(tags.sharedChanges.map(\.key).contains("ALBUM"))
        #expect(tags.files[1].changes.first { $0.key == "TITLE" }?.oldNames == ["title"])
        #expect(tags.keptKeys == ["COMMENT"])

        let plan = AlbumPlan(album: album, release: release, artwork: nil, tags: tags)
        #expect(plan.choice.media == [1, 2])
        try await plan.apply()
        let written = try LibraryAlbum.read(folder)
        #expect(written.files[1].tag("DISCNUMBER") == "2" && written.files[1].tag("DISCTOTAL") == "2")
        #expect(written.files[1].tag("TITLE") == "Track 1" && written.files[1].tag("COMMENT") == "mine")
        #expect(written.files[0].tag("MUSICBRAINZ_ALBUMID") == "rel" && written.choice?.media == [1, 2])
        #expect(try AudioEncoder.decode(folder.appending(path: "02.flac")) == LibraryAlbumTests.threeSeconds)

        let again = AlbumPlan(
            album: written, release: release, artwork: nil,
            tags: AlbumTagsPlan.make(album: written, release: release, fit: fit, settings: settings))
        #expect(!again.hasChanges)
    }

    @Test func keepsTheAlbumNameTheUserGave() async throws {
        let folder = try LibraryAlbumTests().temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "01.flac")
        try AudioEncoder.encode(LibraryAlbumTests.twoSeconds, format: .flac, to: url)
        try FLACTags.write([("ALBUM", "Mine [Remaster]"), ("TRACKNUMBER", "1")], cover: nil, to: url)
        let release = LibraryAlbumTests.release([[2000]])
        let album = try LibraryAlbum.read(folder)
        let fit = try #require(release.fit(lengths: album.lengths))

        let plain = AlbumTagsPlan.make(album: album, release: release, fit: fit)
        #expect(plain.albumTitle == plain.releaseAlbumTitle && plain.editedAlbumTitle == nil)
        let tags = AlbumTagsPlan.make(album: album, release: release, fit: fit, albumTitle: "Theirs [Remaster]")
        #expect(tags.editedAlbumTitle == "Theirs [Remaster]")
        #expect(tags.files[0].merged.filter { $0.key.uppercased() == "ALBUM" }.map(\.value) == ["Theirs [Remaster]"])
        let plan = AlbumPlan(album: album, release: release, artwork: nil, tags: tags)
        #expect(plan.choice.album == "Theirs [Remaster]")
        try await plan.apply()

        // A second run takes the kept name, so nothing changes; the release's name clears it.
        let written = try LibraryAlbum.read(folder)
        #expect(written.files[0].tag("ALBUM") == "Theirs [Remaster]" && written.choice?.album == "Theirs [Remaster]")
        let again = AlbumTagsPlan.make(album: written, release: release, fit: fit)
        #expect(again.albumTitle == "Theirs [Remaster]")
        #expect(!AlbumPlan(album: written, release: release, artwork: nil, tags: again).hasChanges)
        let back = AlbumTagsPlan.make(album: written, release: release, fit: fit, albumTitle: again.releaseAlbumTitle)
        let backPlan = AlbumPlan(album: written, release: release, artwork: nil, tags: back)
        #expect(backPlan.choice.album == nil && backPlan.hasChanges)
        // Without the tags, the kept name stays chosen.
        #expect(
            AlbumPlan(album: written, release: release, artwork: nil, tags: nil).choice.album == "Theirs [Remaster]")
    }

    /// A network share's EBUSY, however deep under Foundation's errors, means the file is in use.
    @Test func knowsAFileInUse() {
        let busy = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
        let inner = NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: busy])
        let outer = NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: inner])
        #expect(LibraryAlbumWriter.isInUse(outer))
        #expect(!LibraryAlbumWriter.isInUse(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        let message = AlbumWriteError.filesInUse([URL(filePath: "/a/01 Song.m4a")]).description
        #expect(message.hasPrefix("“01 Song.m4a” is open in another program") && message.contains("was not changed"))
    }

    /// A run that wrote one file's track number and not another's (it was in use) leaves the
    /// pairing as it was: the next run reads the files in the kept order, not the tags'.
    @Test func keepsThePairingAfterAFileWasSkipped() async throws {
        let folder = try LibraryAlbumTests().temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // No tags: the files pair with the tracks by their names.
        try AudioEncoder.encode(LibraryAlbumTests.twoSeconds, format: .flac, to: folder.appending(path: "a.flac"))
        try AudioEncoder.encode(LibraryAlbumTests.threeSeconds, format: .flac, to: folder.appending(path: "b.flac"))
        let album = try LibraryAlbum.read(folder)
        let release = LibraryAlbumTests.release([[2000, 3000]])
        let fit = try #require(release.fit(lengths: album.lengths))
        var tags = AlbumTagsPlan.make(album: album, release: release, fit: fit)
        // a.flac was in use: only b.flac gets its tags (TRACKNUMBER 2).
        tags.files[0].changes = []
        let plan = AlbumPlan(album: album, release: release, artwork: nil, tags: tags)
        #expect(plan.choice.files == ["a.flac", "b.flac"])
        try await plan.apply()

        let again = try LibraryAlbum.read(folder)
        #expect(again.files[1].trackNumber == 2 && again.files[0].trackNumber == nil)
        #expect(again.files.map(\.url.lastPathComponent) == ["a.flac", "b.flac"])
        let refit = try #require(release.fit(lengths: again.lengths))
        let rest = AlbumTagsPlan.make(album: again, release: release, fit: refit)
        #expect(rest.files[0].track.position == 1 && !rest.files[0].changes.isEmpty && rest.files[1].changes.isEmpty)

        // Without the kept order, the tags' order would put a.flac last.
        try FileManager.default.removeItem(at: folder.appending(path: AlbumChoice.fileName))
        #expect(try LibraryAlbum.read(folder).files.map(\.url.lastPathComponent) == ["b.flac", "a.flac"])
    }
}
