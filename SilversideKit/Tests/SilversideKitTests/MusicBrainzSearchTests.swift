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

    @Test func makesTheQuery() {
        #expect(
            MusicBrainzClient.searchQuery(for: " dave brubeck seven classic lps ") == "dave brubeck seven classic lps")
        #expect(MusicBrainzClient.searchQuery(for: "AC/DC: Back in Black!") == "AC\\/DC\\: Back in Black\\!")
        #expect(MusicBrainzClient.searchQuery(for: "catno:EN4CD9161") == "catno:EN4CD9161")
        #expect(MusicBrainzClient.searchQuery(for: "brubeck (catno:EN4CD9161)") == "brubeck (catno:EN4CD9161)")
        // Titles with a field's name in them are words, not fields.
        #expect(MusicBrainzClient.searchQuery(for: "Soundtracks: Vol. 1") == "Soundtracks\\: Vol. 1")
        #expect(MusicBrainzClient.searchQuery(for: "Classic Country: Hits") == "Classic Country\\: Hits")
        // A "+" reaches MusicBrainz as a "+", not a space.
        let url = MusicBrainzClient.searchURL(query: MusicBrainzClient.searchQuery(for: "Mumford + Sons"), limit: 5)
        #expect(url.absoluteString.contains("query=Mumford%20%5C%2B%20Sons"))
        #expect(
            MusicBrainzClient.searchQuery(for: "823564030142") == "barcode:0823564030142 OR barcode:823564030142")
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
    }
}
