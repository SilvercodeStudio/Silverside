import Foundation

/// A release for MusicBrainz's release editor, filled in from a disc that MusicBrainz does
/// not know: the names (with the user's edits), the track lengths, and the disc's TOC, which
/// attaches its disc ID when the release is added. MusicBrainz takes these as a form posted
/// to its "add release" page ("release editor seeding"), so the page in `page(for:toc:)`
/// posts the form when a browser opens it. The user reviews the release there and submits it.
///
/// A disc that MusicBrainz knows only as part of another release, such as the single-disc
/// edition of a box set's first disc, gets a new release copied from that one
/// (`newRelease: true`): the same release group, names, and recordings, but not the barcode
/// or catalog numbers, which are the other product's.
public enum MusicBrainzSeed {
    public static let addReleaseURL = URL(string: "https://musicbrainz.org/release/add")!
    /// MusicBrainz's "Various Artists".
    public static let variousArtistsID = MusicBrainzRelease.variousArtistsID

    /// The form's fields, in order. Names that Silverside made up ("Unknown Album", "Track 3")
    /// are left out, so the editor shows them as missing.
    public static func fields(
        for release: MusicBrainzRelease, toc: TOC, newRelease: Bool = false
    ) -> [(name: String, value: String)] {
        var fields = [(name: String, value: String)]()
        let placeholder = MusicBrainzRelease.manual(toc: toc)
        if release.title != placeholder.title { fields.append(("name", release.title)) }
        let albumArtist = release.artist
        if albumArtist != placeholder.artist {
            fields += credit(release.artistCredit, prefix: "artist_credit")
        }
        if newRelease {
            if let group = release.releaseGroup { fields.append(("release_group", group.id)) }
            if let status = release.status { fields.append(("status", status.lowercased())) }
        }
        if let date = release.date {
            let parts = date.split(separator: "-")
            for (key, part) in zip(["year", "month", "day"], parts) {
                fields.append(("events.0.date.\(key)", String(part)))
            }
        }
        if let country = release.country { fields.append(("events.0.country", country)) }
        if !newRelease, let barcode = release.barcode, !barcode.isEmpty { fields.append(("barcode", barcode)) }
        for (index, label) in release.labels.enumerated() {
            if let name = label.name { fields.append(("labels.\(index).name", name)) }
            if !newRelease, let number = label.catalogNumber {
                fields.append(("labels.\(index).catalog_number", number))
            }
        }
        let medium = release.medium(for: toc) ?? release.media.first
        // A Mixed Mode CD's data track is track 1, and the disc ID counts it, so the tracklist
        // has it too, as MusicBrainz names a data track, numbered 0 so that the songs keep the
        // sleeve's numbers (as *The Freedom Sessions* has it).
        let dataFirst = Array(toc.tracks.prefix { $0.kind == .data })
        let format = dataFirst.isEmpty ? "CD" : "Mixed Mode CD"
        fields.append(("mediums.0.format", newRelease ? medium?.format ?? format : format))
        // The TOC adds the disc ID, and gives MusicBrainz the tracks' exact lengths.
        fields.append(("mediums.0.toc", toc.musicBrainzTOCString.replacingOccurrences(of: "+", with: " ")))
        for (index, tocTrack) in dataFirst.enumerated() {
            let prefix = "mediums.0.track.\(index)"
            fields.append(("\(prefix).name", "[data track]"))
            fields.append(("\(prefix).number", "0"))
            fields.append(
                ("\(prefix).length", String(toc.sectorRange(of: tocTrack).count * 1000 / CDDA.sectorsPerSecond)))
            if albumArtist != placeholder.artist, !MusicBrainzRelease.isVariousArtists(albumArtist) {
                fields += credit(release.artistCredit, prefix: "\(prefix).artist_credit")
            }
        }
        for (audioIndex, (track, tocTrack)) in zip(medium?.tracks ?? [], toc.audioTracks).enumerated() {
            let index = dataFirst.count + audioIndex
            let prefix = "mediums.0.track.\(index)"
            if track.title != "Track \(tocTrack.number)" { fields.append(("\(prefix).name", track.title)) }
            fields.append(("\(prefix).number", String(audioIndex + 1)))
            // The same recordings: the new release is another edition of the same audio.
            if newRelease, let recording = track.recordingID { fields.append(("\(prefix).recording", recording)) }
            fields.append(
                ("\(prefix).length", String(toc.sectorRange(of: tocTrack).count * 1000 / CDDA.sectorsPerSecond)))
            // MusicBrainz needs an artist on every track: the track's own, else the album's. A track
            // of "Various Artists" gets none, so the editor asks for it.
            if track.artist != albumArtist, track.artist != placeholder.artist {
                fields += credit(track.artistCredit, prefix: "\(prefix).artist_credit")
            } else if albumArtist != placeholder.artist, !MusicBrainzRelease.isVariousArtists(albumArtist) {
                fields += credit(release.artistCredit, prefix: "\(prefix).artist_credit")
            }
        }
        let source =
            newRelease
            ? " Copied from \(release.pageURL?.absoluteString ?? release.id), which has this disc ID on "
                + (medium.map { "disc \($0.position) of \(release.media.count)" } ?? "one of its discs")
                + "; this release is the disc on its own."
            : ""
        fields.append(
            (
                "edit_note",
                "Added with \(SilversideVersion.program) (https://silverside.app) from a rip of the disc: "
                    + "the TOC and track lengths are the disc's (disc ID \(toc.musicBrainzDiscID))." + source
            ))
        return fields
    }

    /// An artist credit's fields: each name, its join phrase, and its MusicBrainz ID if it has one.
    static func credit(_ credit: [MusicBrainzRelease.Credit], prefix: String) -> [(name: String, value: String)] {
        credit.enumerated().flatMap { index, part -> [(name: String, value: String)] in
            let key = "\(prefix).names.\(index)"
            var fields = [("\(key).name", part.name), ("\(key).artist.name", part.name)]
            let id = part.artistID ?? (MusicBrainzRelease.isVariousArtists(part.name) ? variousArtistsID : nil)
            if let id { fields.append(("\(key).mbid", id)) }
            if !part.joinPhrase.isEmpty { fields.append(("\(key).join_phrase", part.joinPhrase)) }
            return fields
        }
    }

    /// A web page that posts the form to MusicBrainz as soon as it opens, with a button for a
    /// browser that does not run its script.
    public static func page(for release: MusicBrainzRelease, toc: TOC, newRelease: Bool = false) -> String {
        let inputs = fields(for: release, toc: toc, newRelease: newRelease).map {
            "<input type=\"hidden\" name=\"\(escaped($0.name))\" value=\"\(escaped($0.value))\">"
        }
        return """
            <!doctype html>
            <html><head><meta charset="utf-8"><title>Add to MusicBrainz</title></head>
            <body style="font: 15px -apple-system, sans-serif; margin: 3em">
            <form id="seed" method="post" action="\(addReleaseURL.absoluteString)" accept-charset="UTF-8">
            \(inputs.joined(separator: "\n"))
            <p>Opening MusicBrainz's release editor with this disc, \(escaped(release.title))…</p>
            <p><button type="submit">Continue to MusicBrainz</button></p>
            </form>
            <script>document.getElementById("seed").submit()</script>
            </body></html>

            """
    }

    /// Writes the page into the temporary folder, for the browser to open.
    public static func writePage(for release: MusicBrainzRelease, toc: TOC, newRelease: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "Silverside MusicBrainz \(toc.musicBrainzDiscID).html")
        try Data(page(for: release, toc: toc, newRelease: newRelease).utf8).write(to: url)
        return url
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
