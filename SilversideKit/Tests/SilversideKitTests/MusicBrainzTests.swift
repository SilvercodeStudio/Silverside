import Foundation
import Testing

@testable import SilversideKit

struct MusicBrainzTests {
    func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources/MusicBrainz"))
        return try Data(contentsOf: url)
    }

    /// The fuzzy TOC string is the disc ID's numbers in decimal: first and last track, lead-out, starts.
    @Test func tocStringHasTheLeadInAndTheLeadOutFirst() throws {
        let toc = try TOC(musicBrainzOffsets: [150, 20000, 40000], sectors: 60000)
        #expect(toc.musicBrainzTOCString == "1+3+60000+150+20000+40000")
    }

    @Test func asksForTheDiscIDAndTheTOCInOneRequest() throws {
        let toc = try TOC(musicBrainzOffsets: [150, 20000, 40000], sectors: 60000)
        let url = MusicBrainzClient.lookupURL(for: toc).absoluteString
        #expect(url.hasPrefix("https://musicbrainz.org/ws/2/discid/\(toc.musicBrainzDiscID)?"))
        #expect(url.contains("toc=1+3+60000+150+20000+40000") && url.contains("fmt=json") && url.contains("cdstubs=no"))
    }

    @Test func readsAFuzzyMatch() throws {
        let lookup = try MusicBrainzClient.lookup(fromJSON: fixture("fuzzy-example"))
        #expect(!lookup.isExact)
        let release = try #require(lookup.releases.first)
        #expect(release.artist == "Band A & Singer B")
        #expect(release.barcode == "" && release.disambiguation == nil && !release.hasFrontCover)
        let tracks = release.media[0].tracks
        // A track with no credit of its own has the release's.
        #expect(tracks[0].artist == "Band A & Singer B" && tracks[0].length == nil)
        #expect(tracks[1].artist == "Guest" && tracks[1].length == 300_000 && tracks[1].recordingID == "r2")
    }

    /// A saved answer from MusicBrainz (2026-10-20) for disc 1 of *Cornell 5/8/77*: the
    /// US and European editions, and the 11-disc box set that holds the same disc.
    @Test func readsAndRanksARealLookup() throws {
        let lookup = try MusicBrainzClient.lookup(fromJSON: fixture("cornell-1977-disc1"))
        #expect(lookup.isExact)
        let discID = "OPh0ozbfOzmAcafVnhUgSi8QtSo-"
        let ranked = ReleaseRanking.ranked(lookup.releases, discID: discID, mcn: "0081227942557")
        #expect(ranked.map(\.id).first == "aa0d7d7e-1d78-4f78-ba03-7a32c200f660")
        #expect(ranked.last?.title == "May 1977: Get Shown the Light" && ranked.last?.media.count == 11)
        let release = ranked[0]
        let medium = try #require(release.medium(withDiscID: discID))
        #expect(medium.position == 1 && medium.tracks.count == 11)
        #expect(medium.tracks.first?.title == "New Minglewood Blues" && medium.tracks.first?.artist == "Grateful Dead")
        #expect(release.labels.contains { $0.name == "Rhino" && $0.catalogNumber == "R2 557480" })
        #expect(release.releaseGroup?.primaryType == "Album")
        #expect(
            NameTemplate.folder.name(NameTemplate.values(release: release, medium: medium))
                == "Grateful Dead - Cornell 5-8-77 (Disc 1)")
    }

    /// *Saint of Circumstance*: MusicBrainz has no disc IDs for its discs (8, 9, and 5 tracks).
    /// A fuzzy match must still give each disc its own medium.
    @Test func findsTheDiscOfAFuzzyMatchByItsTracks() throws {
        func medium(_ position: Int, lengths: [Int?]) -> MusicBrainzRelease.Medium {
            .init(
                position: position, format: "CD", title: nil, discIDs: [],
                tracks: lengths.enumerated().map {
                    .init(
                        position: $0.offset + 1, number: String($0.offset + 1), title: "T", length: $0.element,
                        artistCredit: [], recordingID: nil)
                })
        }
        let release = MusicBrainzRelease(
            id: "r", title: "Saint of Circumstance", artistCredit: [], date: nil, country: nil, status: nil,
            barcode: nil, disambiguation: nil, labels: [], releaseGroup: nil,
            media: [
                medium(1, lengths: Array(repeating: 400_000, count: 8)),
                medium(2, lengths: Array(repeating: 300_000, count: 9)),
                medium(3, lengths: Array(repeating: 500_000, count: 5)),
                medium(4, lengths: Array(repeating: 200_000, count: 5)),
            ], hasFrontCover: false)
        // Five tracks of 500 s each (37,500 sectors): disc 3, not disc 4, by their lengths.
        let five = try TOC(audioTrackStarts: (0..<5).map { $0 * 37_500 }, leadOutLBA: 5 * 37_500)
        #expect(release.medium(for: five)?.position == 3)
        let nine = try TOC(audioTrackStarts: (0..<9).map { $0 * 22_500 }, leadOutLBA: 9 * 22_500)
        #expect(release.medium(for: nine)?.position == 2)
        // Two discs that fit as well: no guess.
        var unknown = release
        unknown.media[2] = medium(3, lengths: Array(repeating: nil, count: 5))
        unknown.media[3] = medium(4, lengths: Array(repeating: nil, count: 5))
        #expect(unknown.medium(for: five) == nil)
        #expect(release.medium(for: try TOC(audioTrackStarts: [0, 100], leadOutLBA: 200)) == nil)
    }

    @Test func linksToTheDiscIDSubmissionPage() throws {
        let toc = try TOC(musicBrainzOffsets: [150, 20000, 40000], sectors: 60000)
        let url = MusicBrainzRelease.submissionURL(for: toc).absoluteString
        #expect(
            url.hasPrefix("https://musicbrainz.org/cdtoc/attach?id=\(toc.musicBrainzDiscID)&tracks=3&toc=1%203%2060000")
        )
    }

    @Test func refusesSomethingElse() {
        #expect(throws: MusicBrainzError.malformedResponse) {
            try MusicBrainzClient.lookup(fromJSON: Data("{\"error\": \"Not found\"}".utf8))
        }
    }

    @Test func keepsAReleaseInItsOwnForm() throws {
        let release = try #require(try MusicBrainzClient.lookup(fromJSON: fixture("fuzzy-example")).releases.first)
        let copy = try JSONDecoder().decode(MusicBrainzRelease.self, from: JSONEncoder().encode(release))
        #expect(copy == release)
    }

    /// Composers and lyricists come from the works a recording performs, and from the
    /// recording's own relationships; a writer is both; a name is listed once. The genre is
    /// the release group's top vote, with the first of a tie.
    @Test func readsWritersAndTheGenreFromRelationships() throws {
        let lookup = try MusicBrainzClient.lookup(fromJSON: fixture("work-rels-example"))
        let release = try #require(lookup.releases.first)
        let tracks = release.media[0].tracks
        #expect(tracks[0].composers == ["Miles Davis"] && tracks[0].lyricists.isEmpty)
        #expect(tracks[1].composers == ["Miles Davis", "Bill Evans"])
        #expect(tracks[1].lyricists == ["Bill Evans", "Someone"])
        #expect(tracks[2].composers.isEmpty && tracks[2].lyricists.isEmpty)
        #expect(release.genre == "Jazz")
        #expect(release.artistCredit[0].sortName == "Davis, Miles")
    }

    /// A release saved by an older Silverside has no composers, lyricists, or genre.
    @Test func readsAReleaseSavedWithoutWriters() throws {
        let json = """
            {"id":"r","title":"T","artistCredit":[{"name":"A","joinPhrase":""}],"labels":[],"hasFrontCover":false,
             "media":[{"position":1,"discIDs":[],"tracks":[{"position":1,"number":"1","title":"X",
             "artistCredit":[{"name":"A","joinPhrase":""}]}]}]}
            """
        let release = try JSONDecoder().decode(MusicBrainzRelease.self, from: Data(json.utf8))
        #expect(release.media[0].tracks[0].composers.isEmpty && release.genre == nil)
        let again = try JSONDecoder().decode(MusicBrainzRelease.self, from: JSONEncoder().encode(release))
        #expect(again == release)
    }

    @Test func asksForTheRelationshipsThatNameTheWriters() throws {
        let toc = try TOC(musicBrainzOffsets: [150, 20000, 40000], sectors: 60000)
        let url = MusicBrainzClient.lookupURL(for: toc).absoluteString
        #expect(url.contains("work-level-rels") && url.contains("recording-level-rels") && url.contains("genres"))
    }
}
