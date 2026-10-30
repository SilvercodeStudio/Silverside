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

    /// When MusicBrainz answers the disc lookup but not the release's own lookup (a 503 on a
    /// busy evening), the disc keeps its release, without the writers.
    @Test func keepsTheReleaseWhenItsOwnLookupFails() async throws {
        let toc = try TOC(
            musicBrainzOffsets: [150, 25220, 61075, 82890, 116599, 145802, 173575, 189016, 210578, 236749, 251121],
            sectors: 301_681)
        let transport = FakeTransport([
            .status(200, body: String(decoding: try fixture("cornell-1977-disc1"), as: UTF8.self)), .status(500),
        ])
        let directory = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let web = WebClient(
            directory: directory, transport: transport,
            policies: ["musicbrainz.org": .init(interval: .zero, lifetime: .seconds(60))],
            firstRetryDelay: .milliseconds(10))
        let result = try await ReleaseLookup.find(
            toc: toc, mcn: nil, details: true, client: MusicBrainzClient(client: web),
            store: ReleaseChoiceStore(url: directory.appending(path: "ReleaseChoices.json")))
        #expect(result.isExact && result.chosen?.id == "aa0d7d7e-1d78-4f78-ba03-7a32c200f660")
        #expect(result.chosen?.media.first?.tracks.first?.title == "New Minglewood Blues")
        #expect(result.detailsFailure != nil)
        #expect(await transport.requests.count == 2)
    }

    /// `silverside drives` names a disc from the cache, with no request: nothing before the
    /// first lookup, the release after it.
    @Test func namesADiscFromTheCacheOnly() async throws {
        let toc = try TOC(
            musicBrainzOffsets: [150, 25220, 61075, 82890, 116599, 145802, 173575, 189016, 210578, 236749, 251121],
            sectors: 301_681)
        let transport = FakeTransport([
            .status(200, body: String(decoding: try fixture("cornell-1977-disc1"), as: UTF8.self))
        ])
        let directory = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let web = WebClient(
            directory: directory, transport: transport,
            policies: ["musicbrainz.org": .init(interval: .zero, lifetime: .seconds(60))])
        let client = MusicBrainzClient(client: web)
        let store = ReleaseChoiceStore(url: directory.appending(path: "ReleaseChoices.json"))
        #expect(ReleaseLookup.cachedRelease(toc: toc, client: client, store: store) == nil)
        _ = try await client.lookup(toc)
        let release = try #require(ReleaseLookup.cachedRelease(toc: toc, client: client, store: store))
        #expect(release.id == "aa0d7d7e-1d78-4f78-ba03-7a32c200f660")
        #expect(await transport.requests.count == 1)
    }

    /// *KUTX Live! Volume 3* (2026-10-29): MusicBrainz did not know the disc, and its fuzzy match
    /// gave eight 20-track compilations of about 80 minutes whose tracks are not the disc's. Only a
    /// release with a disc whose tracks each come within 3 seconds stays; an exact match keeps all.
    @Test func keepsOnlyTheFuzzyMatchesWhoseTracksFit() throws {
        // The disc's first tracks: 4:49, 3:45, 2:48, 4:42; then 16 tracks of 4:00.
        let seconds = [289, 225, 168, 282] + Array(repeating: 240, count: 16)
        var starts = [0]
        for length in seconds.dropLast() { starts.append(starts.last! + length * 75) }
        let toc = try TOC(audioTrackStarts: starts, leadOutLBA: starts.last! + seconds.last! * 75)
        func release(_ id: String, _ lengths: [Int?]) -> MusicBrainzRelease {
            MusicBrainzRelease(
                id: id, title: id, artistCredit: [], date: nil, country: nil, status: nil, barcode: nil,
                disambiguation: nil, labels: [], releaseGroup: nil,
                media: [
                    .init(
                        position: 1, format: "CD", title: nil, discIDs: [],
                        tracks: lengths.enumerated().map {
                            .init(
                                position: $0.offset + 1, number: String($0.offset + 1), title: "T",
                                length: $0.element.map { $0 * 1000 }, artistCredit: [], recordingID: nil)
                        })
                ], hasFrontCover: false)
        }
        // Another pressing, a second or two off; the same lengths in another order (as long in
        // all); and one whose lengths MusicBrainz does not know.
        let pressing = release("pressing", seconds.map { $0 + 2 })
        let shuffled = release("shuffled", [225, 289, 282, 168] + Array(repeating: 240, count: 16))
        let unknown = release("unknown", Array(repeating: nil, count: 20))
        let fuzzy = MusicBrainzLookup(releases: [shuffled, pressing, unknown], isExact: false)
        #expect(fuzzy.fitting(toc).releases.map(\.id) == ["pressing"])
        let exact = MusicBrainzLookup(releases: [shuffled, unknown], isExact: true)
        #expect(exact.fitting(toc) == exact)
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

    /// A release matched by its track lengths lacks the disc ID; one found by the ID, and a
    /// manual release, do not.
    @Test func tellsAMatchOfTheLengthsFromAMatchOfTheDiscID() throws {
        let toc = try TOC(
            musicBrainzOffsets: [150, 25220, 61075, 82890, 116599, 145802, 173575, 189016, 210578, 236749, 251121],
            sectors: 301_681)
        let exact = try #require(try MusicBrainzClient.lookup(fromJSON: fixture("cornell-1977-disc1")).releases.first)
        #expect(!exact.lacksDiscID(of: toc) && !MusicBrainzRelease.manual(toc: toc).lacksDiscID(of: toc))
        let fuzzy = try #require(try MusicBrainzClient.lookup(fromJSON: fixture("fuzzy-example")).releases.first)
        #expect(fuzzy.lacksDiscID(of: toc))
    }

    /// A release with a CD and a Blu-ray reads as MusicBrainz shows it.
    @Test func namesTheMediaAndLinksToTheRelease() throws {
        let toc = try TOC(musicBrainzOffsets: [150, 20000, 40000], sectors: 60000)
        var release = try #require(try MusicBrainzClient.lookup(fromJSON: fixture("cornell-1977-disc1")).releases.first)
        #expect(release.pageURL?.absoluteString == "https://musicbrainz.org/release/\(release.id)")
        #expect(MusicBrainzRelease.manual(toc: toc).pageURL == nil)
        let medium = release.media[0]
        func formats(_ names: [String?]) -> String {
            release.media = names.map {
                var copy = medium
                copy.format = $0
                return copy
            }
            return release.formats
        }
        #expect(formats(["CD"]) == "CD")
        #expect(formats(["CD", "CD", "CD"]) == "3×CD")
        #expect(formats(["CD", "Blu-ray"]) == "CD + Blu-ray" && !release.isCDsOnly)
        #expect(formats(["CD", "CD"]) == "2×CD" && release.isCDsOnly)
        #expect(formats(["CD", "CD", "DVD-Video", "CD"]) == "3×CD + DVD-Video")
        #expect(formats([nil]) == "(unknown)")
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
        #expect(tracks[0].composers.map(\.name) == ["Miles Davis"] && tracks[0].lyricists.isEmpty)
        #expect(tracks[1].composers.map(\.name) == ["Miles Davis", "Bill Evans"])
        #expect(tracks[1].lyricists.map(\.name) == ["Bill Evans", "Արամ Խաչատրյան"])
        #expect(tracks[2].composers.isEmpty && tracks[2].lyricists.isEmpty)
        // A name in another script gets the alias in the user's language, from the track's credit
        // (MusicBrainz sends none with a relationship's artist); a Latin name does not.
        let armenian = tracks[1].lyricists[1]
        #expect(armenian.localeName == "Aram Khachaturian" && armenian.tagName == "Aram Khachaturian")
        #expect(armenian.shownName == "Aram Khachaturian (Արամ Խաչատրյան)" && armenian.sortName == "Khachaturian, Aram")
        #expect(tracks[1].composers[1].localeName == nil && tracks[1].composers[1].shownName == "Bill Evans")
        #expect(release.genre == "Jazz")
        #expect(release.artistCredit[0].sortName == "Davis, Miles")
    }

    /// A release saved by an older Silverside has no composers, lyricists, or genre.
    @Test func readsAReleaseSavedWithoutWriters() throws {
        let json = """
            {"id":"r","title":"T","artistCredit":[{"name":"A","joinPhrase":""}],"labels":[],"hasFrontCover":false,
             "media":[{"position":1,"discIDs":[],"tracks":[{"position":1,"number":"1","title":"X",
             "artistCredit":[{"name":"A","joinPhrase":""}]},{"position":2,"number":"2","title":"Y",
             "artistCredit":[{"name":"A","joinPhrase":""}],"composers":["Old Name"]}]}]}
            """
        let release = try JSONDecoder().decode(MusicBrainzRelease.self, from: Data(json.utf8))
        #expect(release.media[0].tracks[0].composers.isEmpty && release.genre == nil)
        // A writer saved as a name alone (2026-10-23) still reads.
        #expect(release.media[0].tracks[1].composers == [.init(name: "Old Name")])
        let again = try JSONDecoder().decode(MusicBrainzRelease.self, from: JSONEncoder().encode(release))
        #expect(again == release)
    }

    /// The disc ID resource refuses the recording-level relationships (HTTP 400, seen
    /// 2026-10-23), so only a release lookup asks for them, and for the disc IDs.
    @Test func asksForTheRelationshipsOnlyInAReleaseLookup() throws {
        let toc = try TOC(musicBrainzOffsets: [150, 20000, 40000], sectors: 60000)
        let disc = MusicBrainzClient.lookupURL(for: toc).absoluteString
        #expect(disc.contains("genres") && !disc.contains("level-rels"))
        let release = MusicBrainzClient.releaseURL(id: "r1").absoluteString
        #expect(release.hasPrefix("https://musicbrainz.org/ws/2/release/r1?"))
        for part in [
            "discids", "aliases", "artist-rels", "work-rels", "recording-level-rels", "work-level-rels", "genres",
        ] {
            #expect(release.contains(part))
        }
    }

    /// A saved release lookup (2026-10-23) for *Stone Flower*: the disc IDs of four
    /// pressings, the genre with the most votes, the sort name, and the composers and
    /// lyricists of each track's works, a name once even when two works name it.
    @Test func readsARealReleaseLookup() throws {
        let release = try MusicBrainzClient.release(fromJSON: fixture("stone-flower-release"))
        #expect(release.title == "Stone Flower" && release.media[0].tracks.count == 10)
        #expect(
            release.media[0].discIDs.contains("SM0U32s3tKWHADGGT16ibAm9RJk-") && release.media[0].discIDs.count == 4)
        #expect(release.genre == "Bossa Nova")
        #expect(release.artistCredit[0].sortName == "Jobim, Antônio Carlos")
        let tracks = release.media[0].tracks
        #expect(tracks[0].composers.isEmpty && tracks[0].lyricists.isEmpty)
        #expect(
            tracks[3].composers.map(\.name) == ["Ary Barroso"] && tracks[3].lyricists.map(\.name) == ["Ary Barroso"])
        #expect(tracks[8].composers.map(\.tagName) == ["Antônio Carlos Jobim"])
        #expect(tracks[8].lyricists.map(\.tagName) == ["Chico Buarque"])
    }

    /// A saved answer from MusicBrainz (2026-10-29) for Sarah McLachlan *The Freedom Sessions*,
    /// a Mixed Mode CD: the data track is track 1, and the tracklist has it as "[data track]".
    /// The audio tracks 2 to 9 get the songs, numbered from 1, not the songs one track early.
    @Test func leavesOutTheDataTrackOfAMixedModeCD() throws {
        let starts = [0, 148_584, 169_332, 184_647, 202_455, 217_583, 248_108, 259_838, 277_928]
        let toc = try TOC(
            tracks: starts.enumerated().map { .init(number: $0 + 1, startLBA: $1, kind: $0 == 0 ? .data : .audio) },
            leadOutLBA: 320_378)
        #expect(toc.musicBrainzDiscID == "xYH60C0oTAOYn7y3CWYvrD7RMH4-")
        let lookup = try MusicBrainzClient.lookup(fromJSON: fixture("freedom-sessions"))
        let medium = try #require(lookup.releases.first?.medium(for: toc))
        #expect(medium.tracks.count == toc.audioTracks.count)
        #expect(medium.tracks.first?.title == "Elsewhere" && medium.tracks.first?.position == 1)
        #expect(medium.tracks.last?.title == "Ol’55 / Hold On (acoustic)" && medium.tracks.last?.position == 8)
    }
}
