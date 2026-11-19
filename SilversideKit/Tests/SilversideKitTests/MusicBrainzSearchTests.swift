import Foundation
import Testing

@testable import SilversideKit

/// Searching MusicBrainz, with responses saved from MusicBrainz (2026-11-03) for *Seven Classic
/// LPs*, a box whose pressing's disc IDs MusicBrainz does not have.
struct MusicBrainzSearchTests {
    /// Disc 1 of the box as the user's copy has it: 18 tracks.
    static let disc1 =
        "0:11172:27255:41420:60948:80047:95490:121459:134220:155887:186719:210079:223783:244042:263217:276177:298700:313550:367092"
    static let releaseID = "29eea130-7c68-4540-9319-17716d60f3e5"

    /// The query in MusicBrainz's language for `text`.
    static func query(_ text: String) -> MusicBrainzSearchQuery { MusicBrainzSearchQuery(text) }

    /// Plain words, for MusicBrainz's own search of titles and artists.
    static func plain(_ text: String) -> MusicBrainzSearchQuery { MusicBrainzSearchQuery(text, isPlain: true) }

    @Test func makesTheQuery() {
        // Words go as plain words, which MusicBrainz looks for in the title and the artist,
        // not in the title alone, as it does with words in its language that name no field.
        #expect(
            MusicBrainzClient.searchQuery(for: " valhalla, score, ron goodwin ")
                == Self.plain("valhalla, score, ron goodwin"))
        #expect(MusicBrainzClient.searchQuery(for: "AC/DC: Back in Black!") == Self.plain("AC/DC: Back in Black!"))
        // A catalog number: one word without its spaces in MusicBrainz, and weighted.
        #expect(
            MusicBrainzClient.searchQuery(for: "EN4CD9161")
                == Self.query("catno:(EN4CD9161)^20 OR release:(EN4CD9161) OR artist:(EN4CD9161)"))
        #expect(
            MusicBrainzClient.searchQuery(for: "CK  67862")
                == Self.query("catno:(CK\\ 67862)^20 OR release:(CK  67862) OR artist:(CK  67862)"))
        #expect(
            MusicBrainzClient.searchQuery(for: "CAFE CD 2-732")
                == Self.query("catno:(CAFE\\ CD\\ 2\\-732)^20 OR release:(CAFE CD 2\\-732) OR artist:(CAFE CD 2\\-732)")
        )
        // More words, or none with a digit, are names.
        #expect(MusicBrainzClient.searchQuery(for: "Dave's Picks Volume 54").isPlain)
        #expect(MusicBrainzClient.searchQuery(for: "Coil").isPlain)
        // Text that names a field goes as it is.
        #expect(MusicBrainzClient.searchQuery(for: "catno:EN4CD9161") == Self.query("catno:EN4CD9161"))
        #expect(
            MusicBrainzClient.searchQuery(for: "brubeck (catno:EN4CD9161)") == Self.query("brubeck (catno:EN4CD9161)"))
        #expect(
            MusicBrainzClient.searchQuery(for: "release:valhalla AND artist:goodwin")
                == Self.query("release:valhalla AND artist:goodwin"))
        #expect(
            MusicBrainzClient.searchQuery(for: "Hands of Glory COMMENT:(bonus)")
                == Self.query("Hands of Glory COMMENT:(bonus)"))
        #expect(MusicBrainzClient.searchQuery(for: "   ").text.isEmpty)
        // Titles with a field's name in them are words, not fields.
        #expect(
            MusicBrainzClient.searchQuery(for: "Soundtracks: Vol. 1")
                == Self.query(
                    "catno:(Soundtracks\\:\\ Vol.\\ 1)^20 OR release:(Soundtracks\\: Vol. 1) OR artist:(Soundtracks\\: Vol. 1)"
                ))
        #expect(MusicBrainzClient.searchQuery(for: "Classic Country: Hits") == Self.plain("Classic Country: Hits"))
        #expect(MusicBrainzClient.searchQuery(for: "Status: Quo Live") == Self.plain("Status: Quo Live"))
        // Plain words ask for MusicBrainz's own search; a query in its language does not.
        let plainURL = MusicBrainzClient.searchURL(query: Self.plain("ron goodwin"), limit: 25).absoluteString
        #expect(plainURL.contains("query=ron%20goodwin&") && plainURL.contains("&dismax=true&"))
        #expect(!MusicBrainzClient.searchURL(query: Self.query("catno:x"), limit: 25).absoluteString.contains("dismax"))
        // A "+" reaches MusicBrainz as a "+", not a space.
        let url = MusicBrainzClient.searchURL(query: MusicBrainzClient.searchQuery(for: "Mumford + Sons"), limit: 5)
        #expect(url.absoluteString.contains("Mumford%20%2B%20Sons") && !url.absoluteString.contains("+"))
        #expect(
            MusicBrainzClient.searchQuery(for: "823564030142")
                == Self.query("barcode:0823564030142 OR barcode:823564030142"))
        #expect(MusicBrainzClient.barcodeQuery(for: "0075596194426") == "barcode:0075596194426 OR barcode:075596194426")
        #expect(MusicBrainzClient.barcodeQuery(for: "0000000000000") == nil)
        #expect(MusicBrainzClient.barcodeQuery(for: "12345") == nil)
    }

    @Test func readsTheResults() throws {
        let results = try MusicBrainzClient.searchResults(fromJSON: MusicBrainzTests().fixture("search-brubeck"))
        let box = try #require(results.first)
        #expect(box.id == Self.releaseID && box.score == 100 && box.title == "Seven Classic LPs")
        #expect(box.artist == "Dave Brubeck" && box.barcode == "823564030142" && box.date == nil)
        #expect(box.labels == ["Enlightenment EN4CD9161"] && box.formats == "4×CD")
        #expect(box.media.map(\.trackCount) == [18, 10, 16, 15])
        #expect(box.positions(withTrackCount: 18) == [1] && box.positions(withTrackCount: 12).isEmpty)
        #expect(results.count == 10 && results[1].title == "Dave Brubeck")
        let page = try MusicBrainzClient.searchPage(fromJSON: MusicBrainzTests().fixture("search-brubeck"))
        #expect(page.results == results && page.offset == 0 && page.total == 56000 && page.nextOffset == 10)
    }

    /// A search goes on a page at a time, each page asked for, to 100 results at most.
    @Test func goesOnAPageAtATime() async throws {
        let box = try #require(
            try MusicBrainzClient.searchResults(fromJSON: MusicBrainzTests().fixture("search-brubeck")).first)
        let page = Array(repeating: box, count: 25)
        #expect(MusicBrainzSearchPage(results: page, offset: 0, total: 500).nextOffset == 25)
        #expect(MusicBrainzSearchPage(results: page, offset: 50, total: 500).nextOffset == 75)
        #expect(MusicBrainzSearchPage(results: page, offset: 75, total: 500).nextOffset == nil)
        #expect(MusicBrainzSearchPage(results: page, offset: 0, total: 25).nextOffset == nil)
        #expect(MusicBrainzSearchPage(results: Array(page.prefix(5)), offset: 25, total: 30).nextOffset == nil)
        #expect(MusicBrainzSearchPage(results: [], offset: 25, total: 500).nextOffset == nil)

        // The first page's address has no offset, as before; a later page's has one.
        #expect(!MusicBrainzClient.searchURL(query: Self.query("x"), limit: 25).absoluteString.contains("offset"))
        #expect(
            MusicBrainzClient.searchURL(query: Self.query("x"), limit: 25, offset: 25).absoluteString.contains(
                "&offset=25&"))

        let web = FakeWeb([
            ("https://musicbrainz.org/ws/2/release?query=", try MusicBrainzTests().fixture("search-brubeck"))
        ])
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = MusicBrainzClient(client: await web.client(in: root))
        let second = try await client.searchReleasePage("dave brubeck", offset: 25)
        #expect(second.results.count == 10 && second.total == 56000)
        let requests = await web.requests
        #expect(requests.count == 1 && requests[0].contains("offset=25") && requests[0].contains("limit=25"))
        #expect(requests[0].contains("query=dave%20brubeck&") && requests[0].contains("dismax=true"))
    }

    /// A link to a release, or its ID alone, gives that release, looked up by its ID: one
    /// request, and no search. A release group's link searches for its releases.
    @Test func findsTheReleaseOfALink() async throws {
        let id = Self.releaseID
        for text in [
            "https://musicbrainz.org/release/\(id)", "musicbrainz.org/release/\(id)/discids", " \(id.uppercased()) ",
            "https://beta.musicbrainz.org/release/\(id)?tport=8000\n",
        ] {
            #expect(MusicBrainzClient.link(in: text) == .release(id))
        }
        #expect(MusicBrainzClient.searchQuery(for: "https://musicbrainz.org/release/\(id)") == Self.query("reid:\(id)"))
        let group = "0a2b3c4d-1111-4222-8333-444455556666"
        #expect(MusicBrainzClient.link(in: "https://musicbrainz.org/release-group/\(group)") == .releaseGroup(group))
        #expect(
            MusicBrainzClient.searchQuery(for: "https://musicbrainz.org/release-group/\(group)")
                == Self.query("rgid:\(group)"))
        #expect(MusicBrainzClient.link(in: "https://musicbrainz.org/artist/\(group)") == .other)
        #expect(MusicBrainzClient.link(in: "https://musicbrainz.org/release/add") == .other)
        #expect(MusicBrainzClient.searchQuery(for: "https://musicbrainz.org/artist/\(group)").text.isEmpty)
        #expect(MusicBrainzClient.link(in: "https://example.com/release/\(id)") == nil)
        #expect(MusicBrainzClient.link(in: "Dave Brubeck \(id)") == nil)
        #expect(MusicBrainzClient.link(in: "823564030142") == nil)

        let tests = MusicBrainzTests()
        let web = FakeWeb([
            ("https://musicbrainz.org/ws/2/release/\(id)", try tests.fixture("seven-classic-lps-release"))
        ])
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = MusicBrainzClient(client: await web.client(in: root))
        let results = try await client.searchReleases("https://musicbrainz.org/release/\(id)")
        let box = try #require(results.first)
        #expect(results.count == 1 && box.id == id && box.title == "Seven Classic LPs" && box.artist == "Dave Brubeck")
        #expect(box.labels == ["Enlightenment EN4CD9161"] && box.barcode == "823564030142" && box.formats == "4×CD")
        #expect(box.media.map(\.trackCount) == [18, 10, 16, 15] && box.positions(withTrackCount: 18) == [1])
        let requests = await web.requests
        #expect(requests.count == 1 && !requests[0].contains("query="))
    }

    /// The disc ID finds nothing; the disc's barcode finds the box, whose disc 1 fits by its
    /// track count and lengths. One search, and one lookup of the release.
    @Test func findsAReleaseByTheDiscsBarcode() async throws {
        let toc = try TOC(ctdbTOCString: Self.disc1)
        let tests = MusicBrainzTests()
        let web = FakeWeb([
            ("https://musicbrainz.org/ws/2/release?query=barcode", try tests.fixture("search-barcode-823564030142")),
            ("https://musicbrainz.org/ws/2/release/\(Self.releaseID)", try tests.fixture("seven-classic-lps-release")),
        ])
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = MusicBrainzClient(client: await web.client(in: root))
        let release = try #require(
            try MusicBrainzClient.release(fromJSON: tests.fixture("seven-classic-lps-release")) as MusicBrainzRelease?)
        #expect(release.medium(for: toc)?.position == 1 && release.medium(withDiscID: toc.musicBrainzDiscID) == nil)
        #expect(release.fit(for: toc).map { ($0.medium.position, $0.kind) } ?? (0, .discID) == (1, .lengths))

        let result = try await ReleaseLookup.find(
            toc: toc, mcn: "0823564030142", client: client,
            store: ReleaseChoiceStore(url: root.appending(path: "choices.json")))
        #expect(result.foundByBarcode && !result.isExact && result.chosen?.id == Self.releaseID)
        let requests = await web.requests
        #expect(requests.count == 3 && requests[1].contains("barcode:0823564030142"))

        // No barcode, no search.
        let none = try await ReleaseLookup.find(
            toc: toc, mcn: nil, client: client, store: ReleaseChoiceStore(url: root.appending(path: "choices.json")))
        #expect(none.ranked.isEmpty && !none.foundByBarcode)
        #expect(await web.requests.count == 3)

        // The user said that the release is not this disc: the lookup chooses none, and keeps
        // the release for the picker, until a release is chosen for the disc again.
        let store = ReleaseChoiceStore(url: root.appending(path: "choices.json"))
        try store.rememberNoRelease(forDiscID: toc.musicBrainzDiscID)
        let declined = try await ReleaseLookup.find(toc: toc, mcn: "0823564030142", client: client, store: store)
        #expect(declined.chosen == nil && declined.ranked.map(\.id) == [Self.releaseID])
        try store.remember(release, forDiscID: toc.musicBrainzDiscID)
        #expect(!store.hasNoRelease(forDiscID: toc.musicBrainzDiscID))
        #expect(store.choices(forDiscID: toc.musicBrainzDiscID) == [Self.releaseID])
        let chosen = try await ReleaseLookup.find(toc: toc, mcn: "0823564030142", client: client, store: store)
        #expect(chosen.chosen?.id == Self.releaseID)
    }

    /// A release with a length that MusicBrainz lacks on one disc: the disc whose known lengths
    /// fit is the one checked, and the one the files get.
    @Test func checksTheMediumTheFilesGet() throws {
        let toc = try TOC(audioTrackStarts: [0, 15000], leadOutLBA: 30000)
        var release = MusicBrainzRelease.manual(toc: toc)
        release.id = "search-result"
        release.media[0].discIDs = []
        release.media[0].tracks[1].length = nil
        var other = release.media[0]
        other.position = 2
        other.tracks[0].length = 207000
        other.tracks[1].length = 200000
        release.media.append(other)
        #expect(release.fit(for: toc)?.medium.position == 1 && release.medium(for: toc)?.position == 1)
    }
}
