import Foundation

/// Changes to a release's names, kept apart from what MusicBrainz said: the album, its
/// artist and date, and each track's title and artist, by track number on the disc.
/// A rip keeps its edits in `disc.json` ("edits"), and the album-level edits are kept by
/// release ID (`ReleaseEditsStore`), so the other discs of a set get them too. The
/// encoder, the CUE sheet, and the names all use the release with the edits applied.
public struct MetadataEdits: Equatable, Sendable {
    public struct Track: Codable, Equatable, Sendable {
        public var title: String?
        public var artist: String?

        public init(title: String? = nil, artist: String? = nil) {
            self.title = title
            self.artist = artist
        }

        var isEmpty: Bool { title == nil && artist == nil }
    }

    public var album: String?
    public var albumArtist: String?
    /// "1977", "1977-05", or "1977-05-08".
    public var date: String?
    /// By track number on this disc.
    public var tracks: [Int: Track] = [:]

    public init(album: String? = nil, albumArtist: String? = nil, date: String? = nil, tracks: [Int: Track] = [:]) {
        self.album = album
        self.albumArtist = albumArtist
        self.date = date
        self.tracks = tracks
    }

    public var isEmpty: Bool {
        album == nil && albumArtist == nil && date == nil && tracks.values.allSatisfy(\.isEmpty)
    }

    /// The edits that apply to every disc of the release: no track edits.
    public var albumLevel: MetadataEdits {
        MetadataEdits(album: album, albumArtist: albumArtist, date: date)
    }

    /// The edits of this disc's tracks only: no album edits.
    public var trackLevel: MetadataEdits { MetadataEdits(tracks: tracks) }

    /// These edits, with `other`'s on top where it has them.
    public func merged(with other: MetadataEdits) -> MetadataEdits {
        var result = self
        if let album = other.album { result.album = album }
        if let albumArtist = other.albumArtist { result.albumArtist = albumArtist }
        if let date = other.date { result.date = date }
        for (number, track) in other.tracks {
            var merged = result.tracks[number] ?? Track()
            if let title = track.title { merged.title = title }
            if let artist = track.artist { merged.artist = artist }
            result.tracks[number] = merged
        }
        return result
    }

    /// Makes each change from `before` to `after` here too: for names typed on the disc on show
    /// while a copy of it waited for MusicBrainz. Only what changed is taken, by album field and
    /// by track, so the copy's own changes stay where the user changed nothing.
    public mutating func apply(changesFrom before: MetadataEdits, to after: MetadataEdits) {
        if after.album != before.album { album = after.album }
        if after.albumArtist != before.albumArtist { albumArtist = after.albumArtist }
        if after.date != before.date { date = after.date }
        for number in Set(before.tracks.keys).union(after.tracks.keys)
        where before.tracks[number] != after.tracks[number] {
            tracks[number] = after.tracks[number]
        }
    }

    /// Sets one track's title; the original (nil) clears the edit.
    public mutating func setTitle(_ title: String?, ofTrack number: Int) {
        var track = tracks[number] ?? Track()
        track.title = title
        tracks[number] = track.isEmpty ? nil : track
    }

    public mutating func setArtist(_ artist: String?, ofTrack number: Int) {
        var track = tracks[number] ?? Track()
        track.artist = artist
        tracks[number] = track.isEmpty ? nil : track
    }

    /// The release with the edits applied: the album's title, artist, and date, and the
    /// tracks of the medium that holds the disc with `toc`. An edited artist is a plain
    /// credit, with no MusicBrainz artist ID, because the name may be another artist's.
    public func applied(to release: MusicBrainzRelease, toc: TOC) -> MusicBrainzRelease {
        var edited = release
        if let album { edited.title = album }
        if let albumArtist { edited.artistCredit = [.init(name: MusicBrainzRelease.albumArtist(typed: albumArtist))] }
        if let date { edited.date = date }
        // A release Silverside made credits each track to its placeholder album artist ("Unknown
        // Artist"), so a track with no artist of its own takes the album artist as typed.
        let followsAlbum = release.isManual && albumArtist != nil
        guard !tracks.isEmpty || followsAlbum, let medium = release.medium(for: toc),
            let index = edited.media.firstIndex(where: { $0.position == medium.position })
        else { return edited }
        let numbers = toc.audioTracks.map(\.number)
        for (position, track) in edited.media[index].tracks.enumerated() {
            var changed = track
            if followsAlbum, track.artistCredit == release.artistCredit { changed.artistCredit = edited.artistCredit }
            if position < numbers.count, let edit = tracks[numbers[position]] {
                if let title = edit.title { changed.title = title }
                if let artist = edit.artist { changed.artistCredit = [.init(name: artist)] }
            }
            edited.media[index].tracks[position] = changed
        }
        return edited
    }

    /// The edits that give `release` the names that `named` has for the disc with `toc`: the
    /// album's title, artist, and date, and each track's title and artist, where they differ.
    /// For a disc that leaves a custom set, so that it keeps every name it had there.
    public init(keeping named: MusicBrainzRelease, on release: MusicBrainzRelease, toc: TOC) {
        self.init()
        if named.title != release.title { album = named.title }
        if named.artist != release.artist { albumArtist = named.artist }
        if let date = named.date, date != release.date { self.date = date }
        // The tracks as the album edits alone name them: a release Silverside made credits its
        // tracks to the album artist.
        let base = applied(to: release, toc: toc)
        guard let before = named.medium(for: toc) ?? (named.media.count == 1 ? named.media.first : nil),
            let after = base.medium(for: toc)
        else { return }
        for (index, track) in toc.audioTracks.enumerated()
        where index < before.tracks.count && index < after.tracks.count {
            let (old, new) = (before.tracks[index], after.tracks[index])
            if old.title != new.title { setTitle(old.title, ofTrack: track.number) }
            if old.artist != new.artist { setArtist(old.artist, ofTrack: track.number) }
        }
    }

    /// The edits that give a release the names in the disc's CD-Text: the album, its artist,
    /// and each track's title and artist, where CD-Text has a name that differs from the
    /// release's. `medium` is the release's medium for the disc, if the TOC does not find it.
    public init(cdText: CDText, release: MusicBrainzRelease, medium: MusicBrainzRelease.Medium? = nil, toc: TOC) {
        func name(_ text: String?) -> String? {
            let trimmed = text?.trimmingCharacters(in: .whitespaces) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        self.init()
        if let title = name(cdText.titles[0]), title != release.title { album = title }
        if let performer = name(cdText.performers[0]), performer != release.artist { albumArtist = performer }
        let medium = release.medium(for: toc) ?? medium
        for (position, track) in toc.audioTracks.enumerated() {
            let named = medium.flatMap { position < $0.tracks.count ? $0.tracks[position] : nil }
            if let title = name(cdText.trackTitles[track.number]), title != named?.title {
                setTitle(title, ofTrack: track.number)
            }
            if let performer = name(cdText.performers[track.number]), performer != named?.artist {
                setArtist(performer, ofTrack: track.number)
            }
        }
    }

    // MARK: disc.json

    /// The edits in a rip folder's disc.json, if it has any.
    public static func read(fromDiscJSONOf folder: URL) -> MetadataEdits? {
        read(fromReportAt: folder.appending(path: "disc.json"))
    }

    /// The edits beside a report: in a rip's disc.json, or in the album folder's copy of it.
    public static func read(fromReportAt url: URL) -> MetadataEdits? {
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let edits = object["edits"]
        else { return nil }
        return try? JSONDecoder().decode(MetadataEdits.self, from: JSONSerialization.data(withJSONObject: edits))
    }

    /// The names a rip has now: its own edits, with the album edits kept for its release on
    /// top, as the library update writes them. A disc Silverside named has only its own; a
    /// custom set has the set's too. Edits that came from another rip of the same disc do not
    /// count (`ReleaseEditsStore.edits(forReleaseID:rip:)`).
    public static func current(
        forReportAt url: URL, release: MusicBrainzRelease, store: ReleaseEditsStore = ReleaseEditsStore()
    ) -> MetadataEdits {
        let own = read(fromReportAt: url) ?? MetadataEdits()
        guard release.sharesAlbumEdits,
            let kept = store.edits(forReleaseID: release.id, rip: RipIdentity(reportAt: url))
        else { return own }
        return own.merged(with: kept)
    }

    /// Sets "edits" in a folder's disc.json (removes it when there are none), and keeps every other key.
    public func save(inDiscJSONOf folder: URL) throws {
        try save(inReportAt: folder.appending(path: "disc.json"))
    }

    /// Sets "edits" in a report file (removes it when there are none), and keeps every other key.
    public func save(inReportAt url: URL) throws {
        var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        if isEmpty {
            object["edits"] = nil
        } else {
            object["edits"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
        }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}

extension MetadataEdits: Codable {
    private enum CodingKeys: String, CodingKey {
        case album, albumArtist, date, tracks
    }

    /// Tracks are keyed by their number as text ("3"), so the JSON reads as a map.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        album = try container.decodeIfPresent(String.self, forKey: .album)
        albumArtist = try container.decodeIfPresent(String.self, forKey: .albumArtist)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        let byName = try container.decodeIfPresent([String: Track].self, forKey: .tracks) ?? [:]
        tracks = Dictionary(uniqueKeysWithValues: byName.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(album, forKey: .album)
        try container.encodeIfPresent(albumArtist, forKey: .albumArtist)
        try container.encodeIfPresent(date, forKey: .date)
        let kept = tracks.filter { !$0.value.isEmpty }
        if !kept.isEmpty {
            try container.encode(
                Dictionary(uniqueKeysWithValues: kept.map { (String($0.key), $0.value) }), forKey: .tracks)
        }
    }
}

/// A rip, by its disc's TOC (CTDB's string) and the time it was ripped, as its report has them.
public struct RipIdentity: Codable, Equatable, Sendable {
    public var toc: String
    /// The rip's time as its report writes it: ISO 8601, in whole seconds.
    public var ripped: String

    public init(toc: String, date: Date) {
        self.toc = toc
        ripped = ISO8601DateFormatter().string(from: date)
    }

    public init(report: RipReport) {
        self.init(toc: report.toc, date: report.date)
    }

    /// The rip of the report in this file: a rip's disc.json, the album folder's report, or
    /// the archive's manifest, which keeps the report under "ripReport". Nil if the file has neither.
    public init?(reportAt url: URL) {
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let report = object["ripReport"] as? [String: Any] ?? object
        guard let toc = report["toc"] as? String ?? object["toc"] as? String, let ripped = report["date"] as? String
        else { return nil }
        self.toc = toc
        self.ripped = ripped
    }
}

/// The album-level edits for each release, by MusicBrainz release ID, in a JSON file next
/// to the drive profiles. An edit made on one disc of a set applies to the others when
/// they are ripped. Rips in several drives can save at once, so a save locks the file.
///
/// An edit made from a rip records that rip ("from"). It then applies to that rip and to the
/// rips of the release's other discs, but not to the other rips of the same disc: a second
/// rip of a disc, renamed to keep it apart (an album "[PRE]" beside a de-emphasized one,
/// 2026-11-07), must not rename the first. An edit from the set as a whole applies to every rip.
public struct ReleaseEditsStore: Sendable {
    public let url: URL

    public init(url: URL = DriveProfileStore.defaultDirectory.appending(path: "ReleaseEdits.json")) {
        self.url = url
    }

    /// The edits kept for the release, whichever rip they came from: the names a new rip starts with.
    public func edits(forReleaseID releaseID: String) -> MetadataEdits? {
        load()[releaseID]?.edits
    }

    /// The edits kept for the release that apply to `rip`: the newest that did not come from
    /// another rip of the same disc, which keeps its own names. An edit kept before, for every
    /// rip (from before 0.9.5), or from this rip, still applies to it after another rip of the
    /// disc is renamed.
    public func edits(forReleaseID releaseID: String, rip: RipIdentity?) -> MetadataEdits? {
        guard let entry = load()[releaseID] else { return nil }
        return entry.all.first { kept in
            guard let from = kept.from, let rip else { return true }
            return from.toc != rip.toc || from.ripped == rip.ripped
        }?.edits
    }

    /// Keeps the album-level part of `edits` for the release; none removes the rip's entry.
    /// `rip` is the rip the edit was made from; nil for an edit of the whole set, which
    /// replaces every edit kept before. An edit from a rip replaces only that rip's, and the
    /// others stay behind it, for the other rips of the same disc (at most `keptEntries`).
    public func remember(_ edits: MetadataEdits, forReleaseID releaseID: String, from rip: RipIdentity? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = open(url.path + ".lock", O_RDWR | O_CREAT, 0o644)
        guard lock >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { close(lock) }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN) }

        var all = load()
        let album = edits.albumLevel
        var entries = rip == nil ? [] : (all[releaseID]?.all ?? []).filter { $0.from != rip }
        if !album.isEmpty { entries.insert(Entry(edits: album, from: rip), at: 0) }
        entries = Array(entries.prefix(Self.keptEntries))
        all[releaseID] = entries.first.map {
            Entry(edits: $0.edits, from: $0.from, earlier: Array(entries.dropFirst()))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: url, options: .atomic)
    }

    /// The most edits kept for one release, the newest first.
    static let keptEntries = 8

    /// An entry of the file: the newest edits' own keys, so that an older version still reads
    /// them, and beside them "from", and the earlier edits that other rips of the disc keep.
    private struct Entry: Codable {
        var edits: MetadataEdits
        var from: RipIdentity?
        var earlier: [Entry] = []

        /// This entry's edits, then the earlier ones, newest first.
        var all: [Entry] { [Entry(edits: edits, from: from)] + earlier }

        private enum CodingKeys: String, CodingKey { case from, earlier }

        init(edits: MetadataEdits, from: RipIdentity?, earlier: [Entry] = []) {
            self.edits = edits
            self.from = from
            self.earlier = earlier
        }

        init(from decoder: any Decoder) throws {
            edits = try MetadataEdits(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            from = try container.decodeIfPresent(RipIdentity.self, forKey: .from)
            earlier = try container.decodeIfPresent([Entry].self, forKey: .earlier) ?? []
        }

        func encode(to encoder: any Encoder) throws {
            try edits.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(from, forKey: .from)
            if !earlier.isEmpty { try container.encode(earlier, forKey: .earlier) }
        }
    }

    private func load() -> [String: Entry] {
        (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: url))) ?? [:]
    }
}

extension MusicBrainzRelease {
    /// The ID prefix of a release that Silverside made itself, for a disc MusicBrainz does not know.
    public static let manualIDPrefix = "silverside:"
    /// The prefix of such releases made before the app was called Silverside.
    public static let oldManualIDPrefix = "cdrip:"

    /// True for a release Silverside made: it has no MusicBrainz IDs, and no cover in the archive.
    public var isManual: Bool { id.hasPrefix(Self.manualIDPrefix) || id.hasPrefix(Self.oldManualIDPrefix) }

    /// A release for a disc that MusicBrainz does not know: one medium with the disc's
    /// tracks, named from CD-Text where the disc has it, else "Track N". Edits fill in the rest.
    public static func manual(toc: TOC, cdText: CDText? = nil) -> MusicBrainzRelease {
        let albumArtist = cdText?.performers[0].flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Artist"
        let tracks = toc.audioTracks.enumerated().map { index, track in
            Track(
                position: index + 1, number: String(index + 1),
                title: cdText?.trackTitles[track.number].flatMap { $0.isEmpty ? nil : $0 } ?? "Track \(track.number)",
                length: toc.sectorRange(of: track).count * 1000 / CDDA.sectorsPerSecond,
                artistCredit: [.init(name: cdText?.performers[track.number] ?? albumArtist)], recordingID: nil)
        }
        return MusicBrainzRelease(
            id: manualIDPrefix + toc.musicBrainzDiscID,
            title: cdText?.titles[0].flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Album",
            artistCredit: [.init(name: albumArtist)], date: nil, country: nil, status: nil, barcode: nil,
            disambiguation: nil, labels: [], releaseGroup: nil,
            media: [
                .init(position: 1, format: "CD", title: nil, discIDs: [toc.musicBrainzDiscID], tracks: tracks)
            ], hasFrontCover: false)
    }
}
