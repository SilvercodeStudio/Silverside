import Foundation

/// Makes folder and file names from release data.
///
/// A template has fields in braces, such as `{artist} - {album}`. A part in brackets,
/// such as `[ (Disc {disc})]`, is kept only if every field in it has a value: `{disc}`
/// has one only for a release of more than one disc. A `/` in the template makes a
/// subfolder. Values are made safe for file names first, so a `/` in a title does not.
///
/// Fields: `artist` (also `albumArtist`), `album`, `date`, `year`, `disc`, `discs`,
/// `discTitle`, `track` (two digits), `title`, `trackArtist`, and `otherArtist`: the track's
/// artist only when the album's artist is not among the track's credits, as on a compilation
/// (a guest on a band's own album does not count). `{disc:2}` pads a number
/// with zeros to two digits.
public struct NameTemplate: Equatable, Sendable {
    public var pattern: String

    public init(_ pattern: String) {
        self.pattern = pattern
    }

    /// The archive's folder names: "Grateful Dead - Cornell 5/8/77 (Disc 2)".
    public static let folder = NameTemplate("{artist} - {album}[ (Disc {disc})]")

    /// The file names of tracks, with no extension: "03 Scarlet Begonias".
    public static let track = NameTemplate("{track} {title}")

    /// The user's library: an artist folder with one folder for each album, with every disc in it.
    public static let libraryFolder = NameTemplate("{albumArtist}/{album}")

    /// Tracks in the user's library: "18-03 Walkin' Blues" (disc 18, track 3), or "03 Deal" for one
    /// disc. On a compilation, the track's artist comes first: "02 Mark Cromer - Asoka".
    public static let libraryTrack = NameTemplate("[{disc:2}-]{track} [{otherArtist} - ]{title}")

    /// The fields for one track, or for a disc when `track` is nil.
    public static func values(
        release: MusicBrainzRelease, medium: MusicBrainzRelease.Medium?, track: MusicBrainzRelease.Track? = nil
    ) -> [String: String] {
        var values = [
            "artist": release.artist, "albumArtist": release.artist, "album": release.title,
            "discs": String(release.media.count),
        ]
        if let date = release.date {
            values["date"] = date
            values["year"] = String(date.prefix(4))
        }
        if let medium, release.media.count > 1 {
            values["disc"] = String(medium.position)
        }
        if let title = medium?.title { values["discTitle"] = title }
        if let track {
            values["track"] = String(format: "%02d", track.position)
            values["title"] = track.title
            values["trackArtist"] = track.artist
            if !Self.credits(track.artistCredit, include: release.artistCredit) { values["otherArtist"] = track.artist }
        }
        return values
    }

    /// True if every artist of `album` is among `track`'s credits: by MusicBrainz artist ID, or by name.
    static func credits(
        _ track: [MusicBrainzRelease.Credit], include album: [MusicBrainzRelease.Credit]
    ) -> Bool {
        album.allSatisfy { artist in
            track.contains { $0.artistID.map { $0 == artist.artistID } ?? ($0.name == artist.name) }
        }
    }

    /// The name for the values, with each part made safe for the file system.
    public func name(_ values: [String: String]) -> String {
        let safe = values.mapValues(Self.safeComponent)
        var result = ""
        var group: (text: String, complete: Bool)?
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "[" && group == nil {
                group = ("", true)
            } else if character == "]", let finished = group {
                if finished.complete { result += finished.text }
                group = nil
            } else if character == "{", let close = pattern[index...].firstIndex(of: "}") {
                let spec = pattern[pattern.index(after: index)..<close].split(separator: ":", maxSplits: 1)
                var value = spec.first.flatMap { safe[String($0)] }
                if spec.count == 2, let width = Int(spec[1]), let text = value, let number = Int(text) {
                    value = String(format: "%0\(width)d", number)
                }
                if group != nil {
                    group!.text += value ?? ""
                    if value == nil || value!.isEmpty { group!.complete = false }
                } else {
                    result += value ?? ""
                }
                index = pattern.index(after: close)
                continue
            } else if group != nil {
                group!.text.append(character)
            } else {
                result.append(character)
            }
            index = pattern.index(after: index)
        }
        return result.split(separator: "/").map { Self.safeComponent(String($0)) }.joined(separator: "/")
    }

    /// The most bytes of UTF-8 in one file name part. macOS allows 255; this leaves room for an extension.
    static let maximumComponentBytes = 240

    /// A value made safe as a file name part: no "/" or ":" (they become "-"), no control
    /// characters, no spaces or dots at the ends (Finder hides names that start with a dot),
    /// and at most `maximumComponentBytes` of UTF-8.
    public static func safeComponent(_ value: String) -> String {
        var text = String(
            value.unicodeScalars.map { scalar -> Character in
                if scalar == "/" || scalar == ":" { return "-" }
                if CharacterSet.controlCharacters.contains(scalar) { return " " }
                return Character(scalar)
            })
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .").union(.whitespacesAndNewlines))
        while text.utf8.count > maximumComponentBytes { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
