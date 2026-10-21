import Foundation

/// A live show, from a disc title in the form "1985-07-01 Merriweather Post Pavilion, Columbia, MD".
public struct LiveShow: Equatable, Sendable {
    /// The date, "1985-07-01".
    public var date: String
    /// The venue: the part before the first comma, "Merriweather Post Pavilion".
    public var venue: String
    /// The rest, "Columbia, MD", if there is any.
    public var location: String?

    public init?(discTitle: String) {
        let parts = discTitle.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return nil }
        let place = parts[1].trimmingCharacters(in: .whitespaces)
        guard !place.isEmpty else { return nil }
        date = parts[0]
        if let comma = place.range(of: ", ") {
            venue = String(place[..<comma.lowerBound])
            location = String(place[comma.upperBound...])
        } else {
            venue = place
        }
    }

    /// The date as the title suffix shows it: "7-1-85".
    public var shortDate: String {
        let numbers = date.split(separator: "-").compactMap { Int($0) }
        return "\(numbers[1])-\(numbers[2])-\(String(format: "%02d", numbers[0] % 100))"
    }

    /// The suffix for each title: "[Merriweather Post Pavilion, 7-1-85]".
    public var titleSuffix: String { "[\(venue), \(shortDate)]" }
}

/// The names and tags of one track, from its release. File names and tags come from
/// here, so that they agree.
///
/// The live-show style (on by default): when every disc of the release has a title such
/// as "1985-07-01 Merriweather Post Pavilion, Columbia, MD", a disc's DISCSUBTITLE is
/// that title, its DATE is the show's date (the release's date is ORIGINALDATE), and each
/// title ends with "[Merriweather Post Pavilion, 7-1-85]".
public struct TrackMetadata: Equatable, Sendable {
    public let release: MusicBrainzRelease
    public let medium: MusicBrainzRelease.Medium
    public let track: MusicBrainzRelease.Track
    /// The track's ISRC, from the disc.
    public var isrc: String?
    /// The show on this disc, if the live-show style applies.
    public let show: LiveShow?

    public init(
        release: MusicBrainzRelease, medium: MusicBrainzRelease.Medium, track: MusicBrainzRelease.Track,
        isrc: String? = nil, liveShowStyle: Bool = true
    ) {
        self.release = release
        self.medium = medium
        self.track = track
        self.isrc = isrc
        let everyDiscIsAShow = release.media.allSatisfy { $0.title.flatMap(LiveShow.init(discTitle:)) != nil }
        show = liveShowStyle && everyDiscIsAShow ? medium.title.flatMap(LiveShow.init(discTitle:)) : nil
    }

    /// The title, with the show's suffix if the live-show style applies.
    public var title: String {
        show.map { "\(track.title) \($0.titleSuffix)" } ?? track.title
    }

    /// The fields for `NameTemplate`, with the title as the tags have it.
    public var nameValues: [String: String] {
        var values = NameTemplate.values(release: release, medium: medium, track: track)
        values["title"] = title
        if let show { values["date"] = show.date }
        return values
    }

    /// The Vorbis comments, in the order that the user's library has them, then the
    /// MusicBrainz IDs (as MusicBrainz Picard names them) and other codes.
    public var vorbisComments: [(key: String, value: String)] {
        var comments: [(String, String)] = [
            ("TITLE", title), ("ARTIST", track.artist), ("ALBUMARTIST", release.artist), ("ALBUM", release.title),
            ("DISCNUMBER", String(medium.position)), ("DISCTOTAL", String(release.media.count)),
            ("TRACKNUMBER", String(track.position)), ("TRACKTOTAL", String(medium.tracks.count)),
        ]
        if let discTitle = medium.title { comments.append(("DISCSUBTITLE", discTitle)) }
        if let show {
            comments.append(("DATE", show.date))
            if let date = release.date { comments.append(("ORIGINALDATE", date)) }
        } else {
            if let date = release.date { comments.append(("DATE", date)) }
            if let first = release.releaseGroup?.firstReleaseDate, !first.isEmpty, first != release.date {
                comments.append(("ORIGINALDATE", first))
            }
        }
        if let isrc { comments.append(("ISRC", isrc)) }
        if let barcode = release.barcode, !barcode.isEmpty { comments.append(("BARCODE", barcode)) }
        for label in release.labels {
            if let name = label.name { comments.append(("LABEL", name)) }
            if let number = label.catalogNumber { comments.append(("CATALOGNUMBER", number)) }
        }
        if let country = release.country { comments.append(("RELEASECOUNTRY", country)) }
        comments.append(("MUSICBRAINZ_ALBUMID", release.id))
        if let group = release.releaseGroup { comments.append(("MUSICBRAINZ_RELEASEGROUPID", group.id)) }
        if let recording = track.recordingID { comments.append(("MUSICBRAINZ_TRACKID", recording)) }
        for id in release.artistCredit.compactMap(\.artistID) { comments.append(("MUSICBRAINZ_ALBUMARTISTID", id)) }
        for id in track.artistCredit.compactMap(\.artistID) { comments.append(("MUSICBRAINZ_ARTISTID", id)) }
        return comments
    }
}
