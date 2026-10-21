import Testing

@testable import CDRipKit

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
}
