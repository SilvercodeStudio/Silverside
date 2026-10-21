import Foundation
import Testing

@testable import CDRipKit

struct NameTemplateTests {
    func makeRelease(discs: Int, date: String? = "2017-05-05") -> MusicBrainzRelease {
        let track = MusicBrainzRelease.Track(
            position: 3, number: "3", title: "Scarlet Begonias / Fire on the Mountain", length: nil,
            artistCredit: [.init(name: "Grateful Dead")], recordingID: nil)
        return MusicBrainzRelease(
            id: "r", title: "Cornell 5/8/77", artistCredit: [.init(name: "Grateful Dead")], date: date, country: "US",
            status: "Official", barcode: nil, disambiguation: nil, labels: [], releaseGroup: nil,
            media: (1...discs).map { .init(position: $0, format: "CD", title: nil, discIDs: [], tracks: [track]) },
            hasFrontCover: true)
    }

    /// The default names match the archive's: ":" and "/" become "-".
    @Test func namesAFolderAsTheArchiveDoes() {
        let release = makeRelease(discs: 3)
        let values = NameTemplate.values(release: release, medium: release.media[1])
        #expect(NameTemplate.folder.name(values) == "Grateful Dead - Cornell 5-8-77 (Disc 2)")
    }

    @Test func leavesOutTheDiscOfASingleDisc() {
        let release = makeRelease(discs: 1)
        #expect(
            NameTemplate.folder.name(NameTemplate.values(release: release, medium: release.media[0]))
                == "Grateful Dead - Cornell 5-8-77")
    }

    @Test func namesATrack() {
        let release = makeRelease(discs: 3)
        let values = NameTemplate.values(release: release, medium: release.media[0], track: release.media[0].tracks[0])
        #expect(NameTemplate.track.name(values) == "03 Scarlet Begonias - Fire on the Mountain")
    }

    @Test func makesSubfoldersOnlyFromTheTemplate() {
        let release = makeRelease(discs: 3)
        let values = NameTemplate.values(release: release, medium: release.media[2])
        #expect(
            NameTemplate("{artist}/[{year} - ]{album}[/Disc {disc}]").name(values)
                == "Grateful Dead/2017 - Cornell 5-8-77/Disc 3")
        let undated = makeRelease(discs: 1, date: nil)
        #expect(
            NameTemplate("{artist}/[{year} - ]{album}[/Disc {disc}]").name(
                NameTemplate.values(release: undated, medium: undated.media[0])) == "Grateful Dead/Cornell 5-8-77")
    }

    /// The user's library: "Grateful Dead/Summer Magic 1985/18-03 Walkin' Blues".
    @Test func namesTracksAsTheLibraryDoes() {
        let release = makeRelease(discs: 20)
        let values = NameTemplate.values(
            release: release, medium: release.media[17], track: release.media[17].tracks[0])
        #expect(NameTemplate.libraryFolder.name(values) == "Grateful Dead/Cornell 5-8-77")
        #expect(NameTemplate.libraryTrack.name(values) == "18-03 Scarlet Begonias - Fire on the Mountain")
        let single = makeRelease(discs: 1)
        #expect(
            NameTemplate.libraryTrack.name(
                NameTemplate.values(release: single, medium: single.media[0], track: single.media[0].tracks[0]))
                == "03 Scarlet Begonias - Fire on the Mountain")
    }

    /// A compilation names each track's artist; an album by one artist does not.
    @Test func namesTheArtistOfEachTrackOnACompilation() {
        var release = makeRelease(discs: 1)
        release.artistCredit = [.init(name: "Various Artists")]
        release.media[0].tracks[0].artistCredit = [
            .init(name: "Mark Cromer", joinPhrase: " & "), .init(name: "Jeff Briggs"),
        ]
        let values = NameTemplate.values(release: release, medium: release.media[0], track: release.media[0].tracks[0])
        #expect(
            NameTemplate.libraryTrack.name(values)
                == "03 Mark Cromer & Jeff Briggs - Scarlet Begonias - Fire on the Mountain")
        let single = makeRelease(discs: 1)
        #expect(
            NameTemplate.libraryTrack.name(
                NameTemplate.values(release: single, medium: single.media[0], track: single.media[0].tracks[0]))
                == "03 Scarlet Begonias - Fire on the Mountain")
    }

    /// A guest on a band's own album (*Clarity of Cal*): the band is in the credit, so the name has no artist.
    @Test func leavesOutTheArtistOfAGuestTrack() {
        var guest = makeRelease(discs: 1)
        guest.artistCredit = [.init(name: "Vulfpeck", artistID: "v")]
        guest.media[0].tracks[0].artistCredit = [
            .init(name: "Vulfpeck", joinPhrase: " & ", artistID: "v"), .init(name: "Joey Dosik", artistID: "j"),
        ]
        let values = NameTemplate.values(release: guest, medium: guest.media[0], track: guest.media[0].tracks[0])
        #expect(NameTemplate.libraryTrack.name(values) == "03 Scarlet Begonias - Fire on the Mountain")
        #expect(values["trackArtist"] == "Vulfpeck & Joey Dosik")
    }

    @Test func makesValuesSafe() {
        #expect(NameTemplate.safeComponent("  ..Hidden: a/b\tc. ") == "Hidden- a-b c")
        #expect(NameTemplate.safeComponent(String(repeating: "é", count: 200)).utf8.count <= 240)
    }
}
