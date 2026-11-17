import Foundation

/// How `silverside album` puts a release's tags over a file's own: each key that Silverside
/// writes replaces every value of that key (keys compared without case, as Vorbis comments
/// are), and other programs' names for the same field go with it; a key that Silverside has no
/// value for here keeps the file's; every other key stays. Tags that belong to another release
/// go too when the file names another release (`releaseBound`).
public enum TagMerge {
    /// Other programs' keys, and the key that Silverside writes for the same field.
    public static let otherNames: [String: String] = [
        "TOTALTRACKS": "TRACKTOTAL", "TOTALDISCS": "DISCTOTAL", "ALBUM ARTIST": "ALBUMARTIST",
        "ALBUM_ARTIST": "ALBUMARTIST", "YEAR": "DATE", "ORIGINALYEAR": "ORIGINALDATE",
    ]

    /// Tags that describe one release, which go when a file's MUSICBRAINZ_ALBUMID names another
    /// release than the one written, if Silverside does not write them anew: Picard's that
    /// Silverside never writes, and those that Silverside writes only when the release has them.
    public static let releaseBound: Set<String> = [
        "MUSICBRAINZ_RELEASETRACKID", "MUSICBRAINZ_DISCID", "MUSICBRAINZ_ALBUMCOMMENT", "RELEASETYPE",
        "RELEASESTATUS", "SCRIPT", "ASIN", "MEDIA", "BARCODE", "CATALOGNUMBER", "LABEL", "RELEASECOUNTRY",
        "ORIGINALDATE", "ORIGINALYEAR", "DISCSUBTITLE", "COMPILATION", "GENRE", "ISRC",
        "MUSICBRAINZ_ALBUMSTATUS", "MUSICBRAINZ_ALBUMTYPE",
    ]

    /// The keys, in capitals, that the merge takes out of a file: those written, the other
    /// programs' names for them, and with `otherRelease`, the release-bound ones.
    public static func removed(writing new: [(key: String, value: String)], otherRelease: Bool) -> Set<String> {
        let written = Set(new.map { $0.key.uppercased() })
        var removed = written
        for (other, key) in otherNames where written.contains(key) { removed.insert(other) }
        if otherRelease { removed.formUnion(releaseBound) }
        return removed
    }

    /// The keys that Silverside writes from a release (`TrackMetadata.vorbisComments`).
    public static let releaseKeys: Set<String> = [
        "TITLE", "ARTIST", "ALBUMARTIST", "ALBUM", "DISCNUMBER", "DISCTOTAL", "TRACKNUMBER", "TRACKTOTAL",
        "DISCSUBTITLE", "COMPILATION", "DATE", "ORIGINALDATE", "GENRE", "COMPOSER", "LYRICIST", "ISRC", "BARCODE",
        "LABEL", "CATALOGNUMBER", "RELEASECOUNTRY", "ARTISTSORT", "ALBUMARTISTSORT", "MUSICBRAINZ_ALBUMID",
        "MUSICBRAINZ_RELEASEGROUPID", "MUSICBRAINZ_TRACKID", "MUSICBRAINZ_ALBUMARTISTID", "MUSICBRAINZ_ARTISTID",
    ]

    /// The keys, in capitals, that an update of a file Silverside encoded takes out before it
    /// writes `new`: the keys written and other programs' names for them (`removed`), and the
    /// keys that Silverside wrote there last (`lastWritten`, the encoding's record), whose
    /// values it may have no more. Every other key stays, as another program wrote it. When
    /// the file names another release than `new` does, or `new` names none (a disc of no
    /// release), the release-bound keys go too; and with no record (an album encoded before
    /// Silverside kept one), so does every key that Silverside writes from a release.
    public static func removedFromOwnFile(
        _ existing: [(key: String, value: String)], writing new: [(key: String, value: String)],
        lastWritten: Set<String>?
    ) -> Set<String> {
        func release(_ tags: [(key: String, value: String)]) -> String? {
            tags.first { $0.key.uppercased() == "MUSICBRAINZ_ALBUMID" && !$0.value.isEmpty }?.value.lowercased()
        }
        let tagged = release(existing)
        let otherRelease = tagged != nil && tagged != release(new)
        var keys = removed(writing: new, otherRelease: otherRelease)
        keys.formUnion(lastWritten ?? (otherRelease ? releaseKeys : []))
        return keys
    }

    /// The file's tags after the merge: Silverside's first, in the library's order, then the
    /// file's others in their order.
    public static func merged(
        _ existing: [(key: String, value: String)], writing new: [(key: String, value: String)], otherRelease: Bool
    ) -> [(key: String, value: String)] {
        merged(existing, writing: new, removing: removed(writing: new, otherRelease: otherRelease))
    }

    /// `new`, then the file's tags whose keys, in capitals, are not in `keys`.
    public static func merged(
        _ existing: [(key: String, value: String)], writing new: [(key: String, value: String)],
        removing keys: Set<String>
    ) -> [(key: String, value: String)] {
        new + existing.filter { !keys.contains($0.key.uppercased()) }
    }

    /// One key's change, for the report: its values before and after, and the names it had.
    public struct Change: Equatable, Sendable {
        /// The key as Silverside writes it (in capitals), or as the file had it, if it goes.
        public var key: String
        public var old: [String]
        public var new: [String]
        /// How the file wrote the key, where that differs: "album" for ALBUM, "TOTALTRACKS" for TRACKTOTAL.
        public var oldNames: [String]

        public var isAdded: Bool { old.isEmpty }
        public var isRemoved: Bool { new.isEmpty }
        /// The same values, under the key as Silverside writes it.
        public var isRenamedOnly: Bool { old == new }
    }

    /// What changes from `old` to `new`: each key whose values or name differ, in the order of
    /// `new`, then the keys that go.
    public static func changes(from old: [(key: String, value: String)], to new: [(key: String, value: String)])
        -> [Change]
    {
        func canonical(_ key: String) -> String {
            let folded = key.uppercased()
            return otherNames[folded] ?? folded
        }
        var oldValues = [String: [String]]()
        var oldNames = [String: [String]]()
        var oldOrder = [String]()
        for (key, value) in old {
            let name = canonical(key)
            if oldValues[name] == nil { oldOrder.append(name) }
            oldValues[name, default: []].append(value)
            if !oldNames[name, default: []].contains(key) { oldNames[name, default: []].append(key) }
        }
        var newValues = [String: [String]]()
        var newNames = [String: String]()
        var newOrder = [String]()
        for (key, value) in new {
            let name = canonical(key)
            if newValues[name] == nil { newOrder.append(name) }
            newValues[name, default: []].append(value)
            newNames[name] = newNames[name] ?? key
        }
        var changes = [Change]()
        for name in newOrder {
            let before = oldValues[name] ?? []
            let after = newValues[name] ?? []
            let names = (oldNames[name] ?? []).filter { $0 != newNames[name] }
            guard before != after || !names.isEmpty else { continue }
            changes.append(Change(key: newNames[name] ?? name, old: before, new: after, oldNames: names))
        }
        for name in oldOrder where newValues[name] == nil {
            changes.append(
                Change(
                    key: oldNames[name]?.first ?? name, old: oldValues[name] ?? [], new: [],
                    oldNames: oldNames[name] ?? []))
        }
        return changes
    }
}

/// The tags that `silverside album` writes into an album folder's files: the release's, as an
/// encoding from a rip writes them (`TrackMetadata`, with the user's settings), merged over
/// each file's own (`TagMerge`). Worked out before anything is written, for the report.
public struct AlbumTagsPlan: Sendable {
    public struct FilePlan: Sendable {
        public var file: LibraryAlbum.File
        public var medium: MusicBrainzRelease.Medium
        public var track: MusicBrainzRelease.Track
        /// The tags that Silverside writes for the file's track.
        public var written: [(key: String, value: String)]
        /// The keys, in capitals, that the merge takes out of the file (`TagMerge.removed`).
        public var removed: Set<String>
        /// The file's tags after the merge.
        public var merged: [(key: String, value: String)]
        public var changes: [TagMerge.Change]
        /// The file names another release than the one written (MUSICBRAINZ_ALBUMID), so its
        /// release-bound tags go.
        public var otherRelease: Bool
        /// False for a file whose tags Silverside cannot write (`LibraryAlbum.File.canWriteCover`).
        public var canWrite: Bool
    }

    public var files: [FilePlan]
    /// The fit that pairs the files with the release's tracks.
    public var fit: AlbumFit
    /// The album name that the tags get (ALBUM).
    public var albumTitle: String
    /// The release's album name, as Silverside writes it with the user's settings.
    public var releaseAlbumTitle: String

    /// The album name, if the user gave another than the release's, for the kept choice.
    public var editedAlbumTitle: String? { albumTitle == releaseAlbumTitle ? nil : albumTitle }

    public var hasChanges: Bool { files.contains { $0.canWrite && !$0.changes.isEmpty } }

    /// The plan for `release`'s tracks as `fit` pairs them with the album's files, with the
    /// user's settings for the names. `albumTitle` is the album name for the tags; nil takes
    /// the one kept in the folder for this release, else the release's.
    public static func make(
        album: LibraryAlbum, release: MusicBrainzRelease, fit: AlbumFit, settings: Settings = Settings(),
        albumTitle: String? = nil
    ) -> AlbumTagsPlan {
        // The release's track for each file, with its medium, in the fit's order.
        let pairs = fit.media.flatMap { position in
            (release.media.first { $0.position == position }.map { medium in medium.tracks.map { (medium, $0) } }) ?? []
        }
        func metadata(_ medium: MusicBrainzRelease.Medium, _ track: MusicBrainzRelease.Track) -> TrackMetadata {
            TrackMetadata(
                release: release, medium: medium, track: track, liveShowStyle: settings.liveShowStyle,
                plainPunctuation: settings.plainPunctuation, segueMarks: settings.segueMarks,
                compilationFolder: settings.compilationFolder)
        }
        let releaseTitle =
            pairs.first.flatMap { metadata($0.0, $0.1).vorbisComments.first { $0.key == "ALBUM" }?.value }
            ?? release.title
        let kept = album.choice?.releaseID == release.id ? album.choice?.album : nil
        let title = albumTitle ?? kept ?? releaseTitle
        let files = zip(album.files, pairs).map { file, pair -> FilePlan in
            let written = metadata(pair.0, pair.1).vorbisComments.map { tag in
                tag.key == "ALBUM" ? (key: tag.key, value: title) : tag
            }
            let tagged = file.tag("MUSICBRAINZ_ALBUMID").flatMap { $0.isEmpty ? nil : $0 }
            let otherRelease = tagged != nil && tagged?.lowercased() != release.id.lowercased() && !release.isManual
            let merged = TagMerge.merged(file.tags, writing: written, otherRelease: otherRelease)
            return FilePlan(
                file: file, medium: pair.0, track: pair.1, written: written,
                removed: TagMerge.removed(writing: written, otherRelease: otherRelease), merged: merged,
                changes: TagMerge.changes(from: file.tags, to: merged), otherRelease: otherRelease,
                canWrite: file.canWriteCover)
        }
        return AlbumTagsPlan(files: files, fit: fit, albumTitle: title, releaseAlbumTitle: releaseTitle)
    }

    /// The changes that every writable file has alike (the album's: ALBUM, DATE, ...), once, and
    /// each file's others, for the report.
    public var sharedChanges: [TagMerge.Change] {
        let writable = files.filter(\.canWrite)
        guard writable.count > 1, let first = writable.first else { return [] }
        return first.changes.filter { change in writable.allSatisfy { $0.changes.contains(change) } }
    }

    /// The keys that stay as the files have them: those Silverside does not write, in the order
    /// first seen.
    public var keptKeys: [String] {
        var seen = Set<String>()
        var keys = [String]()
        for plan in files where plan.canWrite {
            for (key, _) in plan.file.tags where !plan.removed.contains(key.uppercased()) {
                if seen.insert(key.uppercased()).inserted { keys.append(key) }
            }
        }
        return keys
    }
}
