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

/// Where a segue mark (the ">" at the end of "Scarlet Begonias >") goes. The user's library
/// keeps it in the TITLE tag and leaves it out of the file name.
public enum SegueMarks: String, Codable, CaseIterable, Sendable {
    /// In the tags and the file names.
    case everywhere
    /// In the tags only.
    case tagsOnly = "tags"
    /// Nowhere: the mark is removed.
    case none

    /// The title without a trailing segue mark: "Scarlet Begonias >" becomes "Scarlet Begonias".
    /// A mark in the middle of a title, as in "Dark Star > Jam", is part of the title and stays.
    public static func withoutMark(_ title: String) -> String {
        var text = Substring(title)
        while let last = text.last, last == ">" || last == "→" || last == " " {
            text = text.dropLast()
        }
        return text.isEmpty ? title : String(text)
    }
}

extension MusicBrainzRelease {
    /// MusicBrainz's "Various Artists".
    public static let variousArtistsID = "89ad4ac3-39f7-470e-963a-56509c546377"

    /// True for a release credited to Various Artists.
    public var isCompilation: Bool {
        artistCredit.contains { $0.artistID == Self.variousArtistsID || $0.name == "Various Artists" }
    }
}

/// Typographic punctuation as plain ASCII, as many libraries have it: "Walkin’ Blues" becomes
/// "Walkin' Blues". Quotes, primes, hyphens and dashes, the ellipsis, and the no-break space change.
public enum PlainPunctuation {
    static let replacements: [Character: String] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{2032}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{2033}": "\"",
        "\u{2010}": "-", "\u{2011}": "-", "\u{2012}": "-", "\u{2013}": "-", "\u{2014}": "-", "\u{2212}": "-",
        "\u{2026}": "...", "\u{00A0}": " ",
    ]

    public static func apply(_ text: String) -> String {
        guard text.contains(where: { replacements[$0] != nil }) else { return text }
        return text.map { replacements[$0] ?? String($0) }.joined()
    }
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

    /// Typographic punctuation becomes ASCII in names and tags (see `PlainPunctuation`).
    public let plainPunctuation: Bool
    /// Where a trailing ">" in a title goes.
    public let segueMarks: SegueMarks
    /// The album artist for names on a compilation, in place of "Various Artists". Empty keeps it.
    public let compilationFolder: String

    public init(
        release: MusicBrainzRelease, medium: MusicBrainzRelease.Medium, track: MusicBrainzRelease.Track,
        isrc: String? = nil, liveShowStyle: Bool = true, plainPunctuation: Bool = false,
        segueMarks: SegueMarks = .tagsOnly, compilationFolder: String = ""
    ) {
        self.release = release
        self.medium = medium
        self.track = track
        self.plainPunctuation = plainPunctuation
        self.segueMarks = segueMarks
        self.compilationFolder = compilationFolder
        self.isrc = isrc
        let everyDiscIsAShow = release.media.allSatisfy { $0.title.flatMap(LiveShow.init(discTitle:)) != nil }
        show = liveShowStyle && everyDiscIsAShow ? medium.title.flatMap(LiveShow.init(discTitle:)) : nil
    }

    /// The title as the tags have it, with the show's suffix if the live-show style applies:
    /// "China Cat Sunflower > [Greek Theatre, 6-15-85]".
    public var title: String {
        let base = segueMarks == .none ? SegueMarks.withoutMark(track.title) : track.title
        return text(show.map { "\(base) \($0.titleSuffix)" } ?? base)
    }

    /// The title as the file name has it: the same, without the segue mark unless it goes everywhere.
    public var fileTitle: String {
        let base = segueMarks == .everywhere ? track.title : SegueMarks.withoutMark(track.title)
        return text(show.map { "\(base) \($0.titleSuffix)" } ?? base)
    }

    private func text(_ value: String) -> String {
        plainPunctuation ? PlainPunctuation.apply(value) : value
    }

    /// The fields for `NameTemplate`, with the title as the tags have it.
    public var nameValues: [String: String] {
        var values = NameTemplate.values(release: release, medium: medium, track: track).mapValues(text)
        values["title"] = fileTitle
        if let show { values["date"] = show.date }
        if release.isCompilation, !compilationFolder.isEmpty {
            values["albumArtist"] = compilationFolder
            values["artist"] = compilationFolder
        }
        return values
    }

    /// The Vorbis comments, in the order that the user's library has them, then the
    /// MusicBrainz IDs (as MusicBrainz Picard names them) and other codes.
    public var vorbisComments: [(key: String, value: String)] {
        var comments: [(String, String)] = [
            ("TITLE", title), ("ARTIST", text(track.artist)), ("ALBUMARTIST", text(release.artist)),
            ("ALBUM", text(release.title)),
            ("DISCNUMBER", String(medium.position)), ("DISCTOTAL", String(release.media.count)),
            ("TRACKNUMBER", String(track.position)), ("TRACKTOTAL", String(medium.tracks.count)),
        ]
        if let discTitle = medium.title { comments.append(("DISCSUBTITLE", text(discTitle))) }
        if release.isCompilation { comments.append(("COMPILATION", "1")) }
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
        guard !release.isManual else { return comments }
        comments.append(("MUSICBRAINZ_ALBUMID", release.id))
        if let group = release.releaseGroup { comments.append(("MUSICBRAINZ_RELEASEGROUPID", group.id)) }
        if let recording = track.recordingID { comments.append(("MUSICBRAINZ_TRACKID", recording)) }
        for id in release.artistCredit.compactMap(\.artistID) { comments.append(("MUSICBRAINZ_ALBUMARTISTID", id)) }
        for id in track.artistCredit.compactMap(\.artistID) { comments.append(("MUSICBRAINZ_ARTISTID", id)) }
        return comments
    }
}
