import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import SilversideKit

/// `silverside album`: an album folder that Silverside did not rip, its release, and its artwork.
struct LibraryAlbumTests {
    static let twoSeconds = Array(AudioEncoderTests.samples.prefix(88_200))
    static let threeSeconds = Array(AudioEncoderTests.samples.prefix(132_300))

    func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A FLAC file with tags from another program: a vendor of its own, a tag Silverside does not
    /// write, and a back cover beside the front.
    func otherProgramsFLAC(at url: URL) throws {
        try AudioEncoder.encode(Self.twoSeconds, format: .flac, to: url)
        try FLACTags.write(
            [("TITLE", "Come Together"), ("CUSTOM", "kept"), ("TRACKNUMBER", "1")],
            cover: try EmbeddedCover(try makeJPEG(width: 300, height: 300)), to: url)
        var data = try Data(contentsOf: url)
        let (blocks, audioStart) = try FLACTags.parseBlocks(data)
        var back = try FLACTags.picture(try EmbeddedCover(try makeJPEG(width: 200, height: 200)))
        back.replaceSubrange(0..<4, with: [0, 0, 0, 4])  // Cover (back)
        var comment = blocks.first { $0.type == 4 }!.body
        let vendor = Array(FLACTags.vendor.utf8)
        let other = Array("reference libFLAC 1.4.3".utf8)
        comment.replaceSubrange(
            comment.startIndex..<(comment.startIndex + 4 + vendor.count),
            with: [UInt8(other.count), 0, 0, 0] + other)
        var rebuilt: [(type: UInt8, body: Data)] = blocks.map { $0.type == 4 ? (type: UInt8(4), body: comment) : $0 }
        rebuilt.append((type: 6, body: back))
        data = try FLACTags.assemble(rebuilt, audio: data[audioStart...])
        try data.write(to: url)
    }

    @Test func replacesTheFrontCoverOfAFLACFileAndKeepsEverythingElse() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "01.flac")
        try otherProgramsFLAC(at: url)
        let before = try Data(contentsOf: url)
        let cover = try EmbeddedCover(try makeJPEG(width: 1600, height: 1600))
        let after = try FLACTags.replacingFrontCover(with: cover, in: before)
        #expect(
            try AudioPayload.fingerprint(of: after, kind: .flac) == AudioPayload.fingerprint(of: before, kind: .flac))
        try after.write(to: url)
        #expect(
            try FLACTags.read(url).map { "\($0.key)=\($0.value)" } == [
                "TITLE=Come Together", "CUSTOM=kept", "TRACKNUMBER=1",
            ])
        #expect(try FLACTags.readFrontCover(url) == cover.image.data)
        // The other program's vendor and the back cover stay; there is one front cover.
        let (blocks, _) = try FLACTags.parseBlocks(after)
        #expect(
            String(decoding: blocks.first { $0.type == 4 }!.body.dropFirst(4).prefix(23), as: UTF8.self)
                == "reference libFLAC 1.4.3")
        #expect(try blocks.filter { $0.type == 6 }.map { try FLACTags.pictureType($0.body) }.sorted() == [3, 4])
        #expect(try AudioEncoder.decode(url) == Self.twoSeconds)
    }

    @Test func replacesTheCoverOfAnMP4FileAndKeepsEveryOtherItem() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "01.m4a")
        try AudioEncoder.encode(Self.twoSeconds, format: .alac, to: url)
        try MP4Tags.write(
            [("TITLE", "Come Together"), ("TRACKNUMBER", "1"), ("TRACKTOTAL", "17")],
            cover: try EmbeddedCover(try makeJPEG(width: 300, height: 300)), to: url)
        // An item that iTunes writes and Silverside does not: a comment.
        var data = try Data(contentsOf: url)
        let top = try MP4Tags.atoms(in: data, data.startIndex..<data.endIndex)
        let moov = top.first { $0.type == "moov" }!
        let items = try MP4Tags.existingItems(in: data, moov: moov).map { Data(data[$0.range]) }
        let comment = MP4Tags.atom("©cmt", [MP4Tags.dataAtom(1, Data("from iTunes".utf8))])
        data = try MP4Tags.rewritten(
            data, top: top, moov: moov, mdat: top.first { $0.type == "mdat" }!,
            ilst: MP4Tags.atom("ilst", items + [comment]))
        let cover = try EmbeddedCover(try makeJPEG(width: 1200, height: 1200))
        let after = try MP4Tags.replacingCover(with: cover, in: data)
        #expect(try AudioPayload.fingerprint(of: after, kind: .mp4) == AudioPayload.fingerprint(of: data, kind: .mp4))
        try after.write(to: url)
        let read = try MP4Tags.read(url)
        #expect(read.cover == cover.image.data)
        #expect(read.comments.map { "\($0.key)=\($0.value)" }.contains("TITLE=Come Together"))
        let newTop = try MP4Tags.atoms(in: after, after.startIndex..<after.endIndex)
        let types = try MP4Tags.existingItems(in: after, moov: newTop.first { $0.type == "moov" }!).map(\.type)
        #expect(types.contains("©cmt") && types.filter { $0 == "covr" }.count == 1)
        #expect(try AudioEncoder.decode(url) == Self.twoSeconds)
    }

    /// The rest of meta stays: its handler, and atoms beside ilst such as ID32 and free. Tags
    /// with another handler (QuickTime's mdta, whose items its keys name) are left alone.
    @Test func keepsTheRestOfMetaAndRefusesOtherTags() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "01.m4a")
        try AudioEncoder.encode(Self.twoSeconds, format: .alac, to: url)
        try MP4Tags.write([("TITLE", "Come Together")], cover: nil, to: url)
        var data = try Data(contentsOf: url)
        var top = try MP4Tags.atoms(in: data, data.startIndex..<data.endIndex)
        var moov = top.first { $0.type == "moov" }!
        let items = try MP4Tags.existingItems(in: data, moov: moov).map { Data(data[$0.range]) }
        // meta(ilst) puts what follows the list beside it, in meta.
        let extras = MP4Tags.atom("ID32", [Data(count: 4), Data("id3".utf8)]) + MP4Tags.atom("free", [Data(count: 64)])
        data = try MP4Tags.rewritten(
            data, top: top, moov: moov, mdat: top.first { $0.type == "mdat" }!,
            ilst: MP4Tags.atom("ilst", items) + extras)

        let after = try MP4Tags.replacingCover(with: try EmbeddedCover(try makeJPEG(width: 400, height: 400)), in: data)
        #expect(try AudioPayload.fingerprint(of: after, kind: .mp4) == AudioPayload.fingerprint(of: data, kind: .mp4))
        top = try MP4Tags.atoms(in: after, after.startIndex..<after.endIndex)
        moov = top.first { $0.type == "moov" }!
        let udta = try MP4Tags.atoms(in: after, moov.body).first { $0.type == "udta" }!
        let meta = try MP4Tags.atoms(in: after, udta.body).first { $0.type == "meta" }!
        let children = try MP4Tags.atoms(in: after, (meta.body.lowerBound + 4)..<meta.body.upperBound).map(\.type)
        #expect(children == ["hdlr", "ilst", "ID32", "free"])
        #expect(try MP4Tags.metaHandler(in: after, moov: moov) == "mdir")

        // QuickTime's tags: the same file, with the handler mdta.
        let range = try #require(after.firstRange(of: Data("mdirappl".utf8)))
        var quickTime = after
        quickTime.replaceSubrange(range.lowerBound..<(range.lowerBound + 4), with: Data("mdta".utf8))
        #expect(throws: MP4Error.otherTags("mdta")) {
            try MP4Tags.replacingCover(with: try EmbeddedCover(try makeJPEG(width: 300, height: 300)), in: quickTime)
        }
        try quickTime.write(to: url)
        #expect(!LibraryAlbum.readFile(url).canWriteCover)
    }

    /// A change in what says how to read the audio counts as much as a change in the audio:
    /// FLAC's STREAMINFO, an MP4 track's sample sizes.
    @Test func fingerprintSeesTheTablesThatReadTheAudio() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let flac = folder.appending(path: "a.flac")
        try AudioEncoder.encode(Self.twoSeconds, format: .flac, to: flac)
        var data = try Data(contentsOf: flac)
        let original = try AudioPayload.fingerprint(of: data, kind: .flac)
        let (blocks, _) = try FLACTags.parseBlocks(data)
        data[blocks[0].body.startIndex + 17] ^= 1  // in the total sample count
        #expect(try AudioPayload.fingerprint(of: data, kind: .flac) != original)

        let m4a = folder.appending(path: "a.m4a")
        try AudioEncoder.encode(Self.twoSeconds, format: .alac, to: m4a)
        var mp4 = try Data(contentsOf: m4a)
        let fingerprint = try AudioPayload.fingerprint(of: mp4, kind: .mp4)
        let stsz = try #require(mp4.firstRange(of: Data("stsz".utf8)))
        mp4[stsz.upperBound + 15] ^= 1  // the first sample's size
        #expect(try AudioPayload.fingerprint(of: mp4, kind: .mp4) != fingerprint)
    }

    @Test func fingerprintSeesAChangedSampleOrAMovedChunk() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let flac = folder.appending(path: "a.flac")
        try AudioEncoder.encode(Self.twoSeconds, format: .flac, to: flac)
        var data = try Data(contentsOf: flac)
        let original = try AudioPayload.fingerprint(of: data, kind: .flac)
        data[data.endIndex - 10] ^= 0xFF
        #expect(try AudioPayload.fingerprint(of: data, kind: .flac) != original)

        let m4a = folder.appending(path: "a.m4a")
        try AudioEncoder.encode(Self.twoSeconds, format: .alac, to: m4a)
        let mp4 = try Data(contentsOf: m4a)
        let fingerprint = try AudioPayload.fingerprint(of: mp4, kind: .mp4)
        // New tags without the chunk offsets moved: the index points at other bytes.
        let top = try MP4Tags.atoms(in: mp4, mp4.startIndex..<mp4.endIndex)
        let moov = top.first { $0.type == "moov" }!
        let bigger = MP4Tags.atom("ilst", [MP4Tags.atom("©nam", [MP4Tags.dataAtom(1, Data(count: 5000))])])
        let unshifted = try top.map {
            $0.type == "moov" ? try MP4Tags.newMoov(mp4, moov, ilst: bigger, shift: 0) : Data(mp4[$0.range])
        }.reduce(Data(), +)
        #expect((try? AudioPayload.fingerprint(of: unshifted, kind: .mp4)) != fingerprint)

        // Two chunk offsets swapped, both still in the audio: the same bytes, read in another order.
        var swapped = mp4
        let stco = try #require(mp4.firstRange(of: Data("stco".utf8)))
        let first = stco.upperBound + 8
        #expect(MP4Tags.uint32(mp4, first - 4) >= 2)
        let a = mp4[first..<(first + 4)]
        swapped.replaceSubrange(first..<(first + 4), with: mp4[(first + 4)..<(first + 8)])
        swapped.replaceSubrange((first + 4)..<(first + 8), with: a)
        #expect(try AudioPayload.fingerprint(of: swapped, kind: .mp4) != fingerprint)
        #expect(try AudioPayload.fingerprint(of: Data(mp4), kind: .mp4) == fingerprint)
    }

    @Test func writesAFileOnlyWhenItsAudioStaysTheSame() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "01.flac")
        try otherProgramsFLAC(at: url)
        let cover = try EmbeddedCover(try makeJPEG(width: 500, height: 500))
        try LibraryAlbumWriter.replaceCover(in: url, kind: .flac, with: cover)
        #expect(try FLACTags.readFrontCover(url) == cover.image.data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["01.flac"])
        // A change that touches the audio is refused, and the file stays as it was.
        let before = try Data(contentsOf: url)
        #expect(throws: AudioPayloadError.changed(url)) {
            try LibraryAlbumWriter.rewrite(url, kind: .flac) { data in
                var changed = data
                changed[changed.endIndex - 1] ^= 1
                return changed
            }
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["01.flac"])
    }

    @Test func readsTheFilesInDiscAndTrackOrder() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, disc, track) in [("b.flac", "2", "1"), ("c.flac", "1", "2/2"), ("a.flac", "1", "1/2")] {
            let url = folder.appending(path: name)
            try AudioEncoder.encode(Self.twoSeconds, format: .flac, to: url)
            try FLACTags.write(
                [("DISCNUMBER", disc), ("TRACKNUMBER", track), ("ALBUM", "Abbey Road"), ("ARTIST", "The Beatles")],
                cover: nil, to: url)
        }
        try Data("not audio".utf8).write(to: folder.appending(path: "notes.txt"))
        let album = try LibraryAlbum.read(folder)
        #expect(album.files.map(\.url.lastPathComponent) == ["a.flac", "c.flac", "b.flac"])
        #expect(album.lengths == [2000, 2000, 2000])
        #expect(
            album.commonTag("ALBUM") == "Abbey Road" && album.coverFile == nil
                && album.files.allSatisfy { $0.cover == nil })
        #expect(AlbumReleaseFinder.searchQueries(for: album) == ["release:(Abbey Road) AND artist:(The Beatles)"])
    }

    static func track(_ position: Int, _ length: Int?) -> MusicBrainzRelease.Track {
        .init(
            position: position, number: String(position), title: "Track \(position)", length: length,
            artistCredit: [.init(name: "The Beatles")], recordingID: nil)
    }

    static func release(_ media: [[Int?]], id: String = "rel") -> MusicBrainzRelease {
        MusicBrainzRelease(
            id: id, title: "Album", artistCredit: [.init(name: "The Beatles")], date: "2009", country: "GB",
            status: "Official", barcode: nil, disambiguation: nil, labels: [], releaseGroup: nil,
            media: media.enumerated().map { index, lengths in
                .init(
                    position: index + 1, format: "CD", title: nil, discIDs: [],
                    tracks: lengths.enumerated().map { track($0.offset + 1, $0.element) })
            }, hasFrontCover: true)
    }

    @Test func fitsADiscOrEveryDiscOfASet() {
        let set = Self.release([[120_000, 200_000], [90_000, 60_000, 30_000], [45_000, 50_000]])
        // One disc: the second, by its lengths.
        let disc = set.fit(lengths: [91_000, 59_000, 30_500])
        #expect(disc?.media == [2] && disc?.kind == .lengths && disc?.largestDifference == 1000)
        // The first two discs in one folder.
        #expect(set.fit(lengths: [120_000, 200_000, 90_000, 60_000, 30_000])?.media == [1, 2])
        // Lengths that differ by more than MusicBrainz's tolerance do not fit.
        #expect(set.fit(lengths: [130_000, 200_000]) == nil)
        // A file whose length is not known fits any track.
        #expect(set.fit(lengths: [nil, 50_000])?.media == [3])
        // No lengths in MusicBrainz: the count alone.
        #expect(Self.release([[nil, nil]]).fit(lengths: [1000, 2000])?.kind == .trackCountOnly)
        #expect(MusicBrainzRelease.canFit(trackCounts: [2, 3, 2], files: 5))
        #expect(!MusicBrainzRelease.canFit(trackCounts: [2, 3, 2], files: 9))
        // An Enhanced CD: the search counts its data track.
        #expect(MusicBrainzRelease.canFit(trackCounts: [18], files: 17))
        #expect(!MusicBrainzRelease.canFit(trackCounts: [19], files: 17))
    }

    /// Words in brackets rank releases by their disambiguation and year, not by their title.
    @Test func searchesForTheTitleWithoutItsBrackets() {
        let file = LibraryAlbum.File(
            url: URL(filePath: "/Music/The Beatles/Abbey Road/01.m4a"), kind: .mp4, milliseconds: 1000,
            tags: [("ALBUM", "Abbey Road (2009 Stereo Remaster)"), ("ARTIST", "The Beatles")], cover: nil)
        let album = LibraryAlbum(
            folder: URL(filePath: "/Music/The Beatles/Abbey Road"), files: [file], coverFile: nil, coverPicture: nil,
            artworkCount: 0, choice: nil)
        #expect(
            AlbumReleaseFinder.searchQueries(for: album) == [
                "release:(Abbey Road) AND artist:(The Beatles) AND comment:(2009 Stereo Remaster)",
                "release:(Abbey Road) AND artist:(The Beatles)",
            ])
        // With no tags, the folder's names: Artist/Album. Brackets in a folder's name are left
        // out, and not looked for in the disambiguation.
        var untagged = album
        untagged.files[0].tags = []
        #expect(AlbumReleaseFinder.searchQueries(for: untagged) == ["release:(Abbey Road) AND artist:(The Beatles)"])
        untagged.folder = URL(filePath: "/Music/Bob Dylan/Duelling Banjos (1986) [FLAC]")
        #expect(AlbumReleaseFinder.searchQueries(for: untagged) == ["release:(Duelling Banjos) AND artist:(Bob Dylan)"])
    }

    @Test func findsTheReleaseIDInAPageURL() {
        #expect(
            AlbumReleaseFinder.releaseID(in: "https://musicbrainz.org/release/C93E1D4C-89FA-3139-9C65-8542A39F07D1")
                == "c93e1d4c-89fa-3139-9c65-8542a39f07d1")
        #expect(AlbumReleaseFinder.releaseID(in: "Abbey Road") == nil)
    }

    /// A release lookup's JSON, with tracks of these lengths.
    static func releaseJSON(id: String, title: String, lengths: [Int]) -> Data {
        let tracks = lengths.enumerated().map { index, length in
            #"{"position": \#(index + 1), "number": "\#(index + 1)", "title": "Song \#(index + 1)", "length": \#(length)}"#
        }.joined(separator: ", ")
        return Data(
            #"""
            {"id": "\#(id)", "title": "\#(title)", "artist-credit": [{"name": "The Beatles", "joinphrase": ""}],
             "date": "2009-09-09", "country": "GB", "status": "Official", "barcode": "0094638246817",
             "label-info": [], "cover-art-archive": {"front": true, "count": 2},
             "media": [{"position": 1, "format": "CD", "tracks": [\#(tracks)]}]}
            """#.utf8)
    }

    static let first = "11111111-1111-1111-1111-111111111111"
    static let second = "22222222-2222-2222-2222-222222222222"
    static let third = "33333333-3333-3333-3333-333333333333"

    static func searchJSON() -> Data {
        func result(_ id: String, score: Int, tracks: Int) -> String {
            #"{"id": "\#(id)", "score": \#(score), "title": "Abbey Road", "artist-credit": [{"name": "The Beatles"}], "media": [{"format": "CD", "track-count": \#(tracks)}]}"#
        }
        return Data(
            #"{"releases": [\#(result(first, score: 100, tracks: 2)), \#(result(second, score: 90, tracks: 2)), \#(result(third, score: 80, tracks: 5))]}"#
                .utf8)
    }

    func album(in folder: URL, tagged releaseID: String? = nil) throws -> LibraryAlbum {
        for (index, samples) in [Self.twoSeconds, Self.threeSeconds].enumerated() {
            let url = folder.appending(path: "0\(index + 1).flac")
            try AudioEncoder.encode(samples, format: .flac, to: url)
            var tags: [(key: String, value: String)] = [
                ("TRACKNUMBER", "\(index + 1)"), ("ALBUM", "Abbey Road"), ("ARTIST", "The Beatles"),
            ]
            if let releaseID { tags.append(("MUSICBRAINZ_ALBUMID", releaseID)) }
            try FLACTags.write(tags, cover: try EmbeddedCover(try makeJPEG(width: 300, height: 300)), to: url)
        }
        return try LibraryAlbum.read(folder)
    }

    /// A search gives the releases whose tracks fit, for the user to choose from; one that is
    /// tagged or kept is used at once.
    @Test func findsTheReleaseFromTheTagsOrBySearch() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let web = FakeWeb([
            (
                "https://musicbrainz.org/ws/2/release/\(Self.first)",
                Self.releaseJSON(id: Self.first, title: "Abbey Road", lengths: [2000, 3000])
            ),
            (
                "https://musicbrainz.org/ws/2/release/\(Self.second)",
                Self.releaseJSON(id: Self.second, title: "Abbey Road", lengths: [2400, 2600])
            ),
            (
                "https://musicbrainz.org/ws/2/release/\(Self.third)",
                Self.releaseJSON(id: Self.third, title: "Abbey Road", lengths: [1, 2, 3, 4, 5])
            ),
            ("https://musicbrainz.org/ws/2/release?", Self.searchJSON()),
        ])
        let finder = AlbumReleaseFinder(
            client: MusicBrainzClient(client: await web.client(in: folder.appending(path: ".cache"))))

        let searched = try await finder.find(for: try album(in: folder))
        #expect(searched.chosen == nil)
        #expect(searched.candidates.map(\.release.id) == [Self.first, Self.second])
        #expect(searched.candidates[0].fit?.largestDifference == 0)
        // The release with five tracks is not looked up.
        #expect(!(await web.requests).contains { $0.contains("release/\(Self.third)") })

        let tagged = try await finder.find(for: try album(in: folder, tagged: Self.second))
        #expect(tagged.chosen?.release.id == Self.second && tagged.chosen?.source == .tags)
        let given = try await finder.find(
            for: try album(in: folder), releaseID: "https://musicbrainz.org/release/\(Self.first)")
        #expect(given.chosen?.source == .given)
    }

    static func listingJSON(release: String) -> Data {
        Data(
            #"""
            {"release": "https://musicbrainz.org/release/\#(release)", "images": [
              {"id": 101, "types": ["Front"], "front": true, "back": false, "comment": "",
               "image": "http://coverartarchive.org/release/\#(release)/101.jpg"},
              {"id": 102, "types": ["Back"], "front": false, "back": true, "comment": "",
               "image": "http://coverartarchive.org/release/\#(release)/102.jpg"},
              {"id": 103, "types": ["Booklet"], "front": false, "back": false, "comment": "page 1",
               "image": "http://coverartarchive.org/release/\#(release)/103.pdf"},
              {"id": 104, "types": ["Raw/Unedited", "Front"], "front": false, "back": false, "comment": "",
               "image": "http://coverartarchive.org/release/\#(release)/104.jpg"}]}
            """#.utf8)
    }

    /// The plan says what changes; writing it gives each file the cover with its other tags,
    /// the folder its cover file, Artwork, and the choice; a second run changes nothing.
    @Test func plansAndWritesTheArtwork() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var album = try album(in: folder)
        // A file Silverside does not write yet.
        try WAVFile.write(Self.twoSeconds, to: folder.appending(path: "03.wav"))
        album = try LibraryAlbum.read(folder)
        let front = try makeJPEG(width: 1400, height: 1400)
        let back = try makeJPEG(width: 800, height: 800)
        let web = FakeWeb([
            ("https://coverartarchive.org/release/\(Self.first)/101", front.data),
            ("https://coverartarchive.org/release/\(Self.first)/102", back.data),
            ("https://coverartarchive.org/release/\(Self.first)/103", Data("%PDF-1.4 booklet".utf8)),
            ("https://coverartarchive.org/release/\(Self.first)", Self.listingJSON(release: Self.first)),
        ])
        let client = CoverArtClient(client: await web.client(in: folder.appending(path: ".cache")))
        let release = try MusicBrainzClient.release(
            fromJSON: Self.releaseJSON(id: Self.first, title: "Abbey Road", lengths: [2000, 3000]))

        let plan = try await AlbumArtworkPlan.make(album: album, release: release, artwork: .all, client: client)
        #expect(plan.front.id == "101" && plan.embedded.width == 1000 && plan.hasChanges)
        #expect(
            plan.files.map(\.change) == [
                .embed(replacing: album.files[0].cover), .embed(replacing: album.files[1].cover), .unsupported,
            ])
        #expect(plan.coverFile == .write)
        // Every image but the cover and the raw scan.
        guard case .replace(let artwork) = plan.artwork else {
            Issue.record("Expected Artwork to be replaced")
            return
        }
        #expect(artwork.map(\.name) == ["back", "booklet"])

        try await plan.apply(client: client)
        let written = try LibraryAlbum.read(folder)
        #expect(written.files[0].tag("TRACKNUMBER") == "1" && written.files[0].tag("ALBUM") == "Abbey Road")
        #expect(written.files[0].cover?.fingerprint == plan.embeddedPicture.fingerprint)
        #expect(written.coverPicture?.width == 1400 && written.coverFile?.lastPathComponent == "cover.jpg")
        #expect(CoverFiles.artwork(in: [folder]).map(\.lastPathComponent) == ["back.jpg", "booklet.pdf"])
        #expect(written.choice?.releaseID == Self.first && written.choice?.frontImageID == "101")
        #expect(written.choice?.artworkImageIDs == ["102", "103"])
        #expect(try AudioEncoder.decode(folder.appending(path: "02.flac")) == Self.threeSeconds)

        // The same choice again, kept in the folder: nothing to change.
        let again = try await AlbumArtworkPlan.make(album: written, release: release, client: client)
        #expect(!again.hasChanges)
        // An album name and media that the tags kept are no change for the cover either.
        var named = try #require(written.choice)
        (named.album, named.media) = ("Mine", [1])
        try named.save(in: folder)
        let withName = try LibraryAlbum.read(folder)
        let cover = try await AlbumArtworkPlan.make(album: withName, release: release, client: client)
        #expect(!cover.hasChanges && cover.choice.album == "Mine")
        #expect(!AlbumPlan(album: withName, release: release, artwork: cover, tags: nil).hasChanges)
        // Another image as the cover: the files and the cover file change, Artwork stays.
        let other = try await AlbumArtworkPlan.make(album: written, release: release, front: "102", client: client)
        #expect(other.hasChanges && other.coverFile == .replace(written.coverPicture))
        if case .unchanged = other.artwork {} else { Issue.record("Expected Artwork to stay") }
    }

    /// The same picture saved by another program, at another JPEG quality, is the same cover;
    /// another picture of the same size is not.
    @Test func knowsTheSamePictureInAnotherEncoding() throws {
        let original = try makeJPEG(width: 800, height: 800)
        let source = try #require(CGImageSourceCreateWithData(original.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let again = try CoverImage.jpeg(image, quality: 0.6)
        #expect(original.data != again.data)
        let picture = LibraryAlbum.Picture(data: original.data)
        #expect(picture.isSamePicture(as: LibraryAlbum.Picture(data: again.data)))
        let flipped = try #require(
            CGContext(
                data: nil, width: 800, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        flipped.translateBy(x: 800, y: 0)
        flipped.scaleBy(x: -1, y: 1)
        flipped.draw(image, in: CGRect(x: 0, y: 0, width: 800, height: 800))
        let other = try CoverImage.jpeg(try #require(flipped.makeImage()), quality: 0.9)
        #expect(!picture.isSamePicture(as: LibraryAlbum.Picture(data: other.data)))
        #expect(!picture.isSamePicture(as: LibraryAlbum.Picture(data: try makeJPEG(width: 700, height: 800).data)))
    }

    /// A folder of one disc of a box set takes the disc's own sleeve as its cover, and with
    /// --artwork all, leaves out the images that name the other discs.
    @Test func takesTheDiscsOwnImagesFromABoxSet() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let album = try album(in: folder)
        let box = "44444444-4444-4444-4444-444444444444"
        let listing = Data(
            #"""
            {"images": [
              {"id": 1, "types": ["Front"], "front": true, "back": false, "comment": "box",
               "image": "http://coverartarchive.org/release/\#(box)/1.jpg"},
              {"id": 2, "types": ["Front"], "front": false, "back": false, "comment": "CD 2",
               "image": "http://coverartarchive.org/release/\#(box)/2.jpg"},
              {"id": 3, "types": ["Booklet"], "front": false, "back": false, "comment": "Disc 3",
               "image": "http://coverartarchive.org/release/\#(box)/3.jpg"},
              {"id": 4, "types": ["Back"], "front": false, "back": true, "comment": "",
               "image": "http://coverartarchive.org/release/\#(box)/4.jpg"}]}
            """#.utf8)
        let web = FakeWeb([
            ("https://coverartarchive.org/release/\(box)/2", try makeJPEG(width: 600, height: 600).data),
            ("https://coverartarchive.org/release/\(box)", listing),
        ])
        let client = CoverArtClient(client: await web.client(in: folder.appending(path: ".cache")))
        let release = Self.release([[60_000], [2000, 3000], [50_000]], id: box)
        let media = try #require(release.fit(lengths: album.lengths)?.media)
        #expect(media == [2])
        let plan = try await AlbumArtworkPlan.make(
            album: album, release: release, media: media, artwork: .all, client: client)
        #expect(plan.front.id == "2" && plan.frontIsSleeve)
        guard case .replace(let artwork) = plan.artwork else {
            Issue.record("Expected Artwork to be replaced")
            return
        }
        #expect(artwork.map(\.image.id) == ["1", "4"] && plan.otherDiscsImages == 1)
    }

    @Test func makesAContactSheet() throws {
        let data = try CoverArtSheet.make([
            .init(label: "1  Front (main front)", image: try makeJPEG(width: 250, height: 250).data),
            .init(label: "2  Back", image: nil),
        ])
        #expect(CoverImage(data: data).fileExtension == "jpg")
        #expect(LibraryAlbum.Picture(data: data).width == 2 * (2 * (220 + 16) + 16))
    }

    @Test func namesArtworkFilesByTheirFormat() {
        #expect(ArtworkFile.fileExtension(of: Data("%PDF-1.7".utf8)) == "pdf")
        #expect(ArtworkFile.fileExtension(of: Data("GIF89a".utf8)) == "gif")
        #expect(ArtworkFile.fileExtension(of: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "jpg")
        #expect(ArtworkFile.fileExtension(of: Data("hello".utf8)) == nil)
    }
}
