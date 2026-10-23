import Testing

@testable import SilversideKit

struct TrackMetadataTests {
    /// Disc 18 of *Summer Magic 1985*, with the disc titles that the user's FLAC files have as DISCSUBTITLE.
    func summerMagic() -> MusicBrainzRelease {
        let titles = (1...20).map {
            $0 == 18 ? "1985-07-01 Merriweather Post Pavilion, Columbia, MD" : "1985-06-14 Greek Theatre, Berkeley, CA"
        }
        let track = MusicBrainzRelease.Track(
            position: 3, number: "3", title: "Walkin' Blues", length: nil,
            artistCredit: [.init(name: "Grateful Dead", artistID: "6faa7ca7")], recordingID: "rec")
        return MusicBrainzRelease(
            id: "rel", title: "Summer Magic 1985", artistCredit: [.init(name: "Grateful Dead", artistID: "6faa7ca7")],
            date: "2026", country: "US", status: "Official", barcode: nil, disambiguation: nil, labels: [],
            releaseGroup: nil,
            media: titles.enumerated().map { index, title in
                .init(
                    position: index + 1, format: "CD", title: title, discIDs: [],
                    tracks: (1...8).map { position in
                        var copy = track
                        copy.position = position
                        return position == 3 ? track : copy
                    })
            },
            hasFrontCover: true)
    }

    @Test func readsAShowFromADiscTitle() throws {
        let show = try #require(LiveShow(discTitle: "1985-07-01 Merriweather Post Pavilion, Columbia, MD"))
        #expect(show.venue == "Merriweather Post Pavilion" && show.location == "Columbia, MD")
        #expect(show.titleSuffix == "[Merriweather Post Pavilion, 7-1-85]")
        #expect(LiveShow(discTitle: "1991-09-26 Boston Garden")?.location == nil)
        #expect(LiveShow(discTitle: "Disc 2: Encores") == nil && LiveShow(discTitle: "1985-07-01") == nil)
    }

    /// The tags and the name agree with the user's file "18-03 Walkin' Blues [Merriweather Post Pavilion, 7-1-85].flac".
    @Test func tagsALiveShowAsTheLibraryDoes() {
        let release = summerMagic()
        let metadata = TrackMetadata(release: release, medium: release.media[17], track: release.media[17].tracks[2])
        let comments = Dictionary(metadata.vorbisComments.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(comments["TITLE"] == "Walkin' Blues [Merriweather Post Pavilion, 7-1-85]")
        #expect(comments["DISCNUMBER"] == "18" && comments["DISCTOTAL"] == "20")
        #expect(comments["TRACKNUMBER"] == "3" && comments["TRACKTOTAL"] == "8")
        #expect(comments["DISCSUBTITLE"] == "1985-07-01 Merriweather Post Pavilion, Columbia, MD")
        #expect(comments["DATE"] == "1985-07-01" && comments["ORIGINALDATE"] == "2026")
        #expect(comments["ALBUMARTIST"] == "Grateful Dead" && comments["MUSICBRAINZ_ALBUMID"] == "rel")
        #expect(
            NameTemplate.libraryTrack.name(metadata.nameValues)
                == "18-03 Walkin' Blues [Merriweather Post Pavilion, 7-1-85]")
    }

    @Test func makesPunctuationPlainWhenAsked() {
        var release = summerMagic()
        release.media[17].tracks[2].title = "Walkin’ Blues"
        release.title = "Brown‐Eyed Women “Live” …"
        let medium = release.media[17]
        let typographic = TrackMetadata(release: release, medium: medium, track: medium.tracks[2])
        #expect(typographic.title.hasPrefix("Walkin’ Blues"))
        let plain = TrackMetadata(release: release, medium: medium, track: medium.tracks[2], plainPunctuation: true)
        #expect(plain.title == "Walkin' Blues [Merriweather Post Pavilion, 7-1-85]")
        #expect(plain.vorbisComments.first { $0.key == "ALBUM" }?.value == "Brown-Eyed Women \"Live\" ...")
        #expect(
            NameTemplate.libraryTrack.name(plain.nameValues)
                == "18-03 Walkin' Blues [Merriweather Post Pavilion, 7-1-85]")
        #expect(PlainPunctuation.apply("Giants Stadium · East Rutherford") == "Giants Stadium · East Rutherford")
    }

    @Test func leavesTheStyleOutWhenADiscIsNotAShow() {
        var release = summerMagic()
        release.media[4].title = nil
        let metadata = TrackMetadata(release: release, medium: release.media[17], track: release.media[17].tracks[2])
        #expect(metadata.title == "Walkin' Blues" && metadata.show == nil)
        let off = TrackMetadata(
            release: summerMagic(), medium: release.media[17], track: release.media[17].tracks[2], liveShowStyle: false)
        #expect(off.title == "Walkin' Blues")
        #expect(off.vorbisComments.first { $0.key == "DATE" }?.value == "2026")
    }

    /// As the library has it: "China Cat Sunflower > [Greek Theatre, 6-15-85]" in the TITLE
    /// tag, "04-01 China Cat Sunflower [Greek Theatre, 6-15-85]" as the file name.
    @Test func keepsSegueMarksInTagsAndOutOfFileNames() {
        var release = summerMagic()
        release.media[3].tracks[0].title = "China Cat Sunflower >"
        let medium = release.media[3]
        let track = medium.tracks[0]
        let tagsOnly = TrackMetadata(release: release, medium: medium, track: track)
        #expect(tagsOnly.title == "China Cat Sunflower > [Greek Theatre, 6-14-85]")
        #expect(
            NameTemplate.libraryTrack.name(tagsOnly.nameValues) == "04-01 China Cat Sunflower [Greek Theatre, 6-14-85]")
        let everywhere = TrackMetadata(release: release, medium: medium, track: track, segueMarks: .everywhere)
        #expect(
            NameTemplate.libraryTrack.name(everywhere.nameValues)
                == "04-01 China Cat Sunflower > [Greek Theatre, 6-14-85]")
        let none = TrackMetadata(release: release, medium: medium, track: track, segueMarks: .none)
        #expect(none.title == "China Cat Sunflower [Greek Theatre, 6-14-85]")
        // A mark in the middle is part of the title.
        #expect(SegueMarks.withoutMark("Dark Star > Jam >") == "Dark Star > Jam")
        #expect(SegueMarks.withoutMark("Drums →") == "Drums")
        #expect(SegueMarks.withoutMark(">") == ">")
    }

    /// A Various Artists release: COMPILATION in the tags, and the folder named as the user likes.
    @Test func namesACompilation() {
        var release = summerMagic()
        release.artistCredit = [.init(name: "Various Artists", artistID: MusicBrainzRelease.variousArtistsID)]
        release.media = [release.media[0]]
        release.media[0].title = nil
        let medium = release.media[0]
        let track = medium.tracks[2]
        #expect(release.isCompilation)
        let plain = TrackMetadata(release: release, medium: medium, track: track)
        #expect(plain.vorbisComments.contains { $0.key == "COMPILATION" && $0.value == "1" })
        #expect(NameTemplate.libraryFolder.name(plain.nameValues) == "Various Artists/Summer Magic 1985")
        #expect(NameTemplate.libraryTrack.name(plain.nameValues) == "03 Grateful Dead - Walkin' Blues")
        let named = TrackMetadata(release: release, medium: medium, track: track, compilationFolder: "Compilations")
        #expect(NameTemplate.libraryFolder.name(named.nameValues) == "Compilations/Summer Magic 1985")
        #expect(named.vorbisComments.first { $0.key == "ALBUMARTIST" }?.value == "Various Artists")
        #expect(!summerMagic().isCompilation)
    }

    /// Composers, lyricists, the genre, and sort names go into the tags when MusicBrainz has them.
    @Test func tagsWritersGenreAndSortNames() {
        var release = summerMagic()
        release.genre = "Rock"
        release.artistCredit = [.init(name: "Grateful Dead", artistID: "6faa7ca7", sortName: "Grateful Dead")]
        var track = release.media[17].tracks[2]
        track.composers = ["Robert Johnson"]
        track.lyricists = ["Robert Johnson"]
        track.artistCredit = [
            .init(name: "Bob Dylan", joinPhrase: " & ", artistID: "b", sortName: "Dylan, Bob"),
            .init(name: "Grateful Dead", artistID: "6faa7ca7", sortName: "Grateful Dead"),
        ]
        let metadata = TrackMetadata(release: release, medium: release.media[17], track: track)
        let comments = metadata.vorbisComments
        #expect(comments.contains { $0 == ("GENRE", "Rock") })
        #expect(comments.contains { $0 == ("COMPOSER", "Robert Johnson") })
        #expect(comments.contains { $0 == ("LYRICIST", "Robert Johnson") })
        #expect(comments.contains { $0 == ("ARTISTSORT", "Dylan, Bob & Grateful Dead") })
        #expect(comments.contains { $0 == ("ALBUMARTISTSORT", "Grateful Dead") })
        // A release with no sort names (typed in, or edited) gets no sort tags.
        let plain = summerMagic()
        let keys = TrackMetadata(release: plain, medium: plain.media[17], track: plain.media[17].tracks[2])
            .vorbisComments.map(\.key)
        #expect(!keys.contains("ARTISTSORT") && !keys.contains("GENRE") && !keys.contains("COMPOSER"))
    }
}
