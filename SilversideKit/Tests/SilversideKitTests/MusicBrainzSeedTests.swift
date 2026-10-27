import Foundation
import Testing

@testable import SilversideKit

/// The form that fills in MusicBrainz's release editor for a disc it does not know.
struct MusicBrainzSeedTests {
    @Test func fillsInTheEditedNamesTheLengthsAndTheTOC() throws {
        let toc = try TOC(audioTrackStarts: [0, 10437, 12400], leadOutLBA: 23775)
        let edits = MetadataEdits(
            album: "Test Disc II", albumArtist: "Various Artists", date: "1989",
            tracks: [
                1: .init(title: "Ambisonic & Channel Ident"),
                2: .init(title: "Spoken \"Channel\" Phasing", artist: "Hi-Fi News"),
            ])
        let release = edits.applied(to: .manual(toc: toc), toc: toc)
        let fields = MusicBrainzSeed.fields(for: release, toc: toc)
        let value = { (name: String) in fields.first { $0.name == name }?.value }
        #expect(value("name") == "Test Disc II")
        #expect(value("artist_credit.names.0.name") == "Various Artists")
        #expect(value("artist_credit.names.0.mbid") == MusicBrainzSeed.variousArtistsID)
        #expect(value("events.0.date.year") == "1989" && value("events.0.date.month") == nil)
        #expect(value("mediums.0.format") == "CD")
        #expect(value("mediums.0.toc") == "1 3 23925 150 10587 12550")
        #expect(value("mediums.0.track.0.name") == "Ambisonic & Channel Ident")
        #expect(value("mediums.0.track.0.length") == String(10437 * 1000 / 75))
        #expect(value("mediums.0.track.1.artist_credit.names.0.name") == "Hi-Fi News")
        // Names that Silverside made up are left for the user to fill in.
        #expect(value("mediums.0.track.2.name") == nil && value("mediums.0.track.2.number") == "3")
        #expect(value("mediums.0.track.0.artist_credit.names.0.name") == nil)
        #expect(value("edit_note")?.contains(toc.musicBrainzDiscID) == true)

        let page = MusicBrainzSeed.page(for: release, toc: toc)
        #expect(page.contains("action=\"https://musicbrainz.org/release/add\" accept-charset=\"UTF-8\""))
        #expect(page.contains("value=\"Spoken &quot;Channel&quot; Phasing\""))
        #expect(page.contains("value=\"Ambisonic &amp; Channel Ident\""))
    }

    /// MusicBrainz needs an artist on every track: an album by one artist gives it to each.
    @Test func givesEachTrackTheAlbumsArtist() throws {
        let toc = try TOC(audioTrackStarts: [0, 1000], leadOutLBA: 2000)
        let edits = MetadataEdits(albumArtist: "Hi-Fi News", tracks: [2: .init(artist: "Eddy Louiss")])
        let fields = MusicBrainzSeed.fields(for: edits.applied(to: .manual(toc: toc), toc: toc), toc: toc)
        let value = { (name: String) in fields.first { $0.name == name }?.value }
        #expect(value("mediums.0.track.0.artist_credit.names.0.name") == "Hi-Fi News")
        #expect(value("mediums.0.track.1.artist_credit.names.0.name") == "Eddy Louiss")
    }

    @Test func leavesOutTheNamesOfAnUntouchedDisc() throws {
        let toc = try TOC(audioTrackStarts: [0, 1000], leadOutLBA: 2000)
        let names = MusicBrainzSeed.fields(for: .manual(toc: toc), toc: toc).map(\.name)
        #expect(!names.contains("name") && !names.contains { $0.hasPrefix("artist_credit") })
        #expect(!names.contains { $0.hasSuffix(".name") })
    }
}
