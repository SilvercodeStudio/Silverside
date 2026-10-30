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

    /// A Mixed Mode CD's data track is track 1, which the disc ID counts: the tracklist starts
    /// with it as "[data track]", numbered 0, and the songs follow from 1.
    @Test func listsTheDataTrackOfAMixedModeCD() throws {
        let toc = try TOC(
            tracks: [.init(number: 1, startLBA: 0, kind: .data), .init(number: 2, startLBA: 3000)], leadOutLBA: 5000)
        let edits = MetadataEdits(albumArtist: "Sarah McLachlan", tracks: [2: .init(title: "Elsewhere")])
        let fields = MusicBrainzSeed.fields(for: edits.applied(to: .manual(toc: toc), toc: toc), toc: toc)
        let value = { (name: String) in fields.first { $0.name == name }?.value }
        #expect(value("mediums.0.format") == "Mixed Mode CD" && value("mediums.0.toc") == "1 2 5150 150 3150")
        #expect(value("mediums.0.track.0.name") == "[data track]" && value("mediums.0.track.0.number") == "0")
        #expect(value("mediums.0.track.0.length") == String(3000 * 1000 / 75))
        #expect(value("mediums.0.track.1.name") == "Elsewhere" && value("mediums.0.track.1.number") == "1")
        #expect(value("mediums.0.track.1.artist_credit.names.0.name") == "Sarah McLachlan")
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

    /// *American Beauty*'s 50th anniversary remaster on one CD: MusicBrainz has its disc ID
    /// only as disc 1 of the 3-disc deluxe edition, so the new release is copied from that.
    @Test func copiesANewReleaseForADiscOfAnotherRelease() throws {
        let toc = try TOC(audioTrackStarts: [0, 1000], leadOutLBA: 2000)
        func medium(_ position: Int, discIDs: [String]) -> MusicBrainzRelease.Medium {
            .init(
                position: position, format: "HDCD", title: nil, discIDs: discIDs,
                tracks: [1, 2].map {
                    .init(
                        position: $0, number: String($0), title: "Song \($0)", length: nil,
                        artistCredit: [.init(name: "Grateful Dead", artistID: "gd")], recordingID: "r\($0)")
                })
        }
        let deluxe = MusicBrainzRelease(
            id: "deluxe", title: "American Beauty", artistCredit: [.init(name: "Grateful Dead", artistID: "gd")],
            date: "2020-10-30", country: "XE", status: "Official", barcode: "603497848515",
            disambiguation: "50th anniversary deluxe edition",
            labels: [.init(name: "Rhino", catalogNumber: "R2 624978")],
            releaseGroup: .init(
                id: "group", title: "American Beauty", primaryType: "Album", secondaryTypes: [],
                firstReleaseDate: "1970-11-01"),
            media: [medium(1, discIDs: [toc.musicBrainzDiscID]), medium(2, discIDs: ["d2"]), medium(3, discIDs: [])],
            hasFrontCover: true)
        let fields = MusicBrainzSeed.fields(for: deluxe, toc: toc, newRelease: true)
        let value = { (name: String) in fields.first { $0.name == name }?.value }
        #expect(value("name") == "American Beauty" && value("release_group") == "group")
        #expect(value("status") == "official" && value("events.0.country") == "XE")
        #expect(value("labels.0.name") == "Rhino")
        // Another product's codes.
        #expect(value("barcode") == nil && value("labels.0.catalog_number") == nil && value("comment") == nil)
        #expect(value("mediums.0.format") == "HDCD" && value("mediums.1.format") == nil)
        #expect(value("mediums.0.track.1.name") == "Song 2" && value("mediums.0.track.1.recording") == "r2")
        #expect(value("mediums.0.track.0.artist_credit.names.0.mbid") == "gd")
        #expect(value("edit_note")?.contains("https://musicbrainz.org/release/deluxe") == true)
        #expect(value("edit_note")?.contains("disc 1 of 3") == true)
        // A disc that MusicBrainz does not know keeps the old form.
        let unknown = MusicBrainzSeed.fields(for: deluxe, toc: toc).map(\.name)
        #expect(
            unknown.contains("barcode") && !unknown.contains("release_group")
                && !unknown.contains { $0.hasSuffix(".recording") })
    }

    @Test func leavesOutTheNamesOfAnUntouchedDisc() throws {
        let toc = try TOC(audioTrackStarts: [0, 1000], leadOutLBA: 2000)
        let names = MusicBrainzSeed.fields(for: .manual(toc: toc), toc: toc).map(\.name)
        #expect(!names.contains("name") && !names.contains { $0.hasPrefix("artist_credit") })
        #expect(!names.contains { $0.hasSuffix(".name") })
    }
}
