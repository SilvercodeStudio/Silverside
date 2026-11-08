import Foundation
import Testing

@testable import SilversideKit

struct MetadataEditsTests {
    func release() -> MusicBrainzRelease {
        func track(_ position: Int, _ title: String) -> MusicBrainzRelease.Track {
            .init(
                position: position, number: String(position), title: title, length: 1000,
                artistCredit: [.init(name: "Grateful Dead", artistID: "gd")], recordingID: "rec\(position)")
        }
        return MusicBrainzRelease(
            id: "rel", title: "Cornell 5/8/77", artistCredit: [.init(name: "Grateful Dead", artistID: "gd")],
            date: "2017-05-05", country: "US", status: "Official", barcode: nil, disambiguation: nil, labels: [],
            releaseGroup: nil,
            media: [
                .init(position: 1, format: "CD", title: nil, discIDs: ["d1"], tracks: [track(1, "A"), track(2, "B")]),
                .init(position: 2, format: "CD", title: nil, discIDs: ["d2"], tracks: [track(1, "C"), track(2, "D")]),
            ], hasFrontCover: true)
    }

    /// Names typed while a copy of the edits changed elsewhere: only what the user changed is taken.
    @Test func takesOnlyWhatChanged() {
        let before = MetadataEdits(album: "Typed", tracks: [1: .init(title: "One"), 2: .init(title: "Two")])
        var after = before
        after.setTitle("Two, retyped", ofTrack: 2)
        after.setTitle("Three", ofTrack: 3)
        after.setTitle(nil, ofTrack: 1)
        // The copy: another release, with its own album edits and a title for track 4.
        var copy = MetadataEdits(album: "Kept for the release", tracks: [4: .init(title: "Four")])
        copy.apply(changesFrom: before, to: after)
        #expect(copy.album == "Kept for the release")
        #expect(copy.tracks[1] == nil && copy.tracks[2]?.title == "Two, retyped" && copy.tracks[3]?.title == "Three")
        #expect(copy.tracks[4]?.title == "Four")
    }

    @Test func appliesAlbumAndTrackEdits() throws {
        let toc = try TOC(audioTrackStarts: [0, 75], leadOutLBA: 150)
        var edits = MetadataEdits(album: "Barton Hall", albumArtist: "The Dead", date: "1977")
        edits.setTitle("Jack Straw", ofTrack: 2)
        // The disc is disc 1 of the release: a fuzzy match by track count fails (two media fit), so by disc ID.
        var release = release()
        release.media[0].discIDs = [toc.musicBrainzDiscID]
        let edited = edits.applied(to: release, toc: toc)
        #expect(edited.title == "Barton Hall" && edited.artist == "The Dead" && edited.date == "1977")
        #expect(edited.artistCredit[0].artistID == nil)
        #expect(edited.media[0].tracks.map(\.title) == ["A", "Jack Straw"])
        #expect(edited.media[1].tracks.map(\.title) == ["C", "D"])
        // The recording stays the same recording.
        #expect(edited.media[0].tracks[1].recordingID == "rec2")
        // Clearing a title removes the edit.
        edits.setTitle(nil, ofTrack: 2)
        #expect(edits.tracks.isEmpty && !edits.isEmpty)
        #expect(edits.albumLevel == edits)
    }

    /// CD-Text with the venue in each title, as *Summer Magic 1985* has it.
    @Test func takesTheNamesFromCDText() throws {
        let toc = try TOC(audioTrackStarts: [0, 75], leadOutLBA: 150)
        var release = release()
        release.media[0].discIDs = [toc.musicBrainzDiscID]
        var cdText = CDText()
        cdText.titles = [0: "Cornell 5/8/77 (Live)", 1: "A (Live at Barton Hall)", 2: "B"]
        cdText.performers = [0: "Grateful Dead", 1: "Grateful Dead", 2: " Donna Jean "]
        let edits = MetadataEdits(cdText: cdText, release: release, toc: toc)
        // Only the names that differ become edits; the album's artist is the same.
        #expect(edits.album == "Cornell 5/8/77 (Live)" && edits.albumArtist == nil)
        #expect(edits.tracks == [1: .init(title: "A (Live at Barton Hall)"), 2: .init(artist: "Donna Jean")])
        let edited = edits.applied(to: release, toc: toc)
        #expect(edited.media[0].tracks.map(\.title) == ["A (Live at Barton Hall)", "B"])
        #expect(MetadataEdits(cdText: CDText(), release: release, toc: toc).isEmpty)
    }

    @Test func mergesWithTheRipsEditsOnTop() {
        let kept = MetadataEdits(album: "Kept", date: "1977")
        var mine = MetadataEdits(album: "Mine")
        mine.setArtist("Donna", ofTrack: 1)
        let merged = kept.merged(with: mine)
        #expect(merged.album == "Mine" && merged.date == "1977" && merged.tracks[1]?.artist == "Donna")
    }

    @Test func roundTripsThroughDiscJSONAndTheStore() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SilversideEdits-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"toc":"2:0:75:150","other":1}"#.utf8).write(to: folder.appending(path: "disc.json"))
        var edits = MetadataEdits(album: "Barton Hall")
        edits.setTitle("Jack Straw", ofTrack: 2)
        try edits.save(inDiscJSONOf: folder)
        #expect(MetadataEdits.read(fromDiscJSONOf: folder) == edits)
        let json = try String(contentsOf: folder.appending(path: "disc.json"), encoding: .utf8)
        #expect(json.contains(#""other" : 1"#) && json.contains(#""2" : {"#))
        try MetadataEdits().save(inDiscJSONOf: folder)
        #expect(MetadataEdits.read(fromDiscJSONOf: folder) == nil)

        let store = ReleaseEditsStore(url: folder.appending(path: "ReleaseEdits.json"))
        try store.remember(edits, forReleaseID: "rel")
        #expect(store.edits(forReleaseID: "rel") == MetadataEdits(album: "Barton Hall"))
        try store.remember(MetadataEdits(), forReleaseID: "rel")
        #expect(store.edits(forReleaseID: "rel") == nil)
    }

    /// An album name kept from one rip of a disc reaches the rips of the release's other discs,
    /// but not another rip of the same disc, which keeps its own names (two rips of *Bob Dylan's
    /// Greatest Hits*, one renamed "[PRE]", 2026-11-07).
    @Test func keptNamesSkipTheOtherRipsOfTheSameDisc() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let release = NameTemplateTests().makeRelease(discs: 2)
        func rip(_ name: String, toc: String, date: String, own: MetadataEdits? = nil) throws -> URL {
            let file = folder.appending(path: "\(name).json")
            var object: [String: Any] = ["toc": toc, "date": date]
            if let own { object["edits"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(own)) }
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            return file
        }
        let first = try rip("first", toc: "1:0:75:150", date: "2026-11-07T18:50:16Z")
        let second = try rip(
            "second", toc: "1:0:75:150", date: "2026-11-07T19:04:06Z", own: MetadataEdits(album: "Hits [PRE]"))
        let otherDisc = try rip("other", toc: "1:0:80:160", date: "2026-11-07T20:00:00Z")
        let store = ReleaseEditsStore(url: folder.appending(path: "ReleaseEdits.json"))
        try store.remember(
            MetadataEdits(album: "Hits [PRE]"), forReleaseID: release.id, from: RipIdentity(reportAt: second))
        #expect(RipIdentity(reportAt: second)?.ripped == "2026-11-07T19:04:06Z")
        func album(_ file: URL) -> String? {
            MetadataEdits.current(forReportAt: file, release: release, store: store).album
        }
        #expect(album(first) == nil)
        #expect(album(second) == "Hits [PRE]" && album(otherDisc) == "Hits [PRE]")
        // A new rip starts with the kept names, and an older version still reads them.
        #expect(store.edits(forReleaseID: release.id)?.album == "Hits [PRE]")
        let old = try JSONDecoder().decode([String: MetadataEdits].self, from: Data(contentsOf: store.url))
        #expect(old[release.id]?.album == "Hits [PRE]")
        // A rip's identity matches the date as its report writes it.
        let date = Date(timeIntervalSince1970: 1_800_000_000.6)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let written = try JSONDecoder().decode([String].self, from: encoder.encode([date]))[0]
        #expect(RipIdentity(toc: "1:0:75:150", date: date).ripped == written)
        // An edit of the whole set reaches every rip.
        try store.remember(MetadataEdits(album: "Greatest Hits"), forReleaseID: release.id)
        #expect(album(first) == "Greatest Hits" && album(second) == "Greatest Hits")
    }

    /// A name kept before edits recorded their rip (before 0.9.5) was every rip's, and the
    /// first rip has no copy of its own: renaming a second rip of the disc leaves it the first
    /// rip's still. A second edit from the second rip replaces only its own.
    @Test func keptNamesFromBeforeStayWithTheOtherRips() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "first.json")
        try Data(#"{"toc":"1:0:100","date":"2026-11-05T12:00:00Z"}"#.utf8).write(to: first)
        let release = release()
        let store = ReleaseEditsStore(url: folder.appending(path: "ReleaseEdits.json"))
        try store.remember(MetadataEdits(album: "Original custom name"), forReleaseID: release.id)
        let second = RipIdentity(toc: "1:0:100", date: Date(timeIntervalSince1970: 1_800_000_000))
        try store.remember(MetadataEdits(album: "Second rip [PRE]"), forReleaseID: release.id, from: second)
        try store.remember(MetadataEdits(album: "Second rip [PRE] 2"), forReleaseID: release.id, from: second)
        #expect(
            MetadataEdits.current(forReportAt: first, release: release, store: store).album == "Original custom name")
        #expect(store.edits(forReleaseID: release.id, rip: second)?.album == "Second rip [PRE] 2")
        #expect(store.edits(forReleaseID: release.id)?.album == "Second rip [PRE] 2")
        // Many later rips' names do not push out the name kept for every rip.
        for day in 1...(ReleaseEditsStore.keptEntries + 2) {
            let rip = RipIdentity(
                toc: "1:0:100", date: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86400))
            try store.remember(MetadataEdits(album: "Rip \(day)"), forReleaseID: release.id, from: rip)
        }
        #expect(
            MetadataEdits.current(forReportAt: first, release: release, store: store).album == "Original custom name")
        // Clearing the second rip's name (or typing MusicBrainz's) takes it back to
        // MusicBrainz's, not to the name from before; the first rip keeps its own.
        try store.remember(MetadataEdits(), forReleaseID: release.id, from: second)
        #expect(store.edits(forReleaseID: release.id, rip: second) == nil)
        #expect(store.edits(forReleaseID: release.id) == nil)
        #expect(
            MetadataEdits.current(forReportAt: first, release: release, store: store).album == "Original custom name")
    }

    @Test func makesAManualReleaseFromCDTextWithoutMusicBrainzIDs() throws {
        let toc = try TOC(audioTrackStarts: [0, 75], leadOutLBA: 150)
        var cdText = CDText()
        cdText.titles = [0: "Live in Vegas", 1: "Opener"]
        cdText.performers = [0: "Phish"]
        let manual = MusicBrainzRelease.manual(toc: toc, cdText: cdText)
        #expect(manual.isManual && manual.title == "Live in Vegas" && manual.artist == "Phish")
        #expect(manual.media[0].tracks.map(\.title) == ["Opener", "Track 2"])
        #expect(manual.medium(for: toc)?.position == 1)
        let metadata = TrackMetadata(release: manual, medium: manual.media[0], track: manual.media[0].tracks[0])
        let keys = metadata.vorbisComments.map(\.key)
        #expect(keys.contains("TITLE") && !keys.contains { $0.hasPrefix("MUSICBRAINZ_") })
        #expect(MusicBrainzRelease.manual(toc: toc).title == "Unknown Album")
    }

    /// A rip's edits reach the encoder: the album folder, the file name, and the tags.
    @Test func encodesWithTheEdits() throws {
        let (folder, library) = try EncodingTests().makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        var edits = MetadataEdits(album: "Giants Stadium 1991")
        edits.setTitle("Help on the Way", ofTrack: 1)
        try edits.save(inDiscJSONOf: folder)
        let disc = try RippedDisc(folder: folder)
        #expect(disc.edits == edits && disc.release?.title == "Giants Stadium 1991")
        let files = try DiscEncoder(format: .flac).encode(disc, into: library)
        #expect(
            files.map { $0.path.replacingOccurrences(of: library.path + "/", with: "") } == [
                "Grateful Dead/Giants Stadium 1991/02-01 Help on the Way.flac",
                "Grateful Dead/Giants Stadium 1991/02-02 Slipknot!.flac",
            ])
        let tags = Dictionary(try FLACTags.read(files[0]).map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(tags["ALBUM"] == "Giants Stadium 1991" && tags["TITLE"] == "Help on the Way")
        #expect(tags["MUSICBRAINZ_ALBUMID"] == "rel" && tags["MUSICBRAINZ_TRACKID"] == "rec1")
    }

    /// "Various Artists" as typed in other ways is MusicBrainz's Various Artists: the release is a
    /// compilation, with the name spelled as MusicBrainz has it. "VA" is not.
    @Test func recognizesVariousArtistsAsTyped() throws {
        for name in [
            "Various Artists", "various artists", "VARIOUS  ARTISTS", " Various-Artists ", "Various Artist", "Various",
            "Vàrious Artists",
        ] {
            #expect(MusicBrainzRelease.isVariousArtists(name), "\(name)")
        }
        for name in ["VA", "va", "V.A.", "Various Artists Band", "The Various Artists", "Artists"] {
            #expect(!MusicBrainzRelease.isVariousArtists(name), "\(name)")
        }
        let toc = try TOC(audioTrackStarts: [0, 1000], leadOutLBA: 2000)
        let edited = MetadataEdits(albumArtist: "various artists").applied(to: .manual(toc: toc), toc: toc)
        #expect(edited.artist == "Various Artists" && edited.isCompilation)
        #expect(MusicBrainzRelease.albumArtist(typed: "VA") == "VA")
    }

    /// A release Silverside made credits its tracks to "Unknown Artist": a track with no artist
    /// of its own takes the album artist as typed, and one with its own keeps it.
    @Test func tracksOfATypedInReleaseFollowItsAlbumArtist() throws {
        let toc = try TOC(audioTrackStarts: [0, 1000], leadOutLBA: 2000)
        let edits = MetadataEdits(albumArtist: "Feist", tracks: [2: .init(artist: "Guest")])
        let tracks = try #require(edits.applied(to: .manual(toc: toc), toc: toc).media.first?.tracks)
        #expect(tracks.map(\.artist) == ["Feist", "Guest"])
    }
}
