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
}
