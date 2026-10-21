import Foundation
import Testing

@testable import CDRipKit

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
}
