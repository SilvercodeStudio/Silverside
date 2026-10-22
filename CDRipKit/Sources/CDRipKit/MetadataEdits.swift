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
        if let albumArtist { edited.artistCredit = [.init(name: albumArtist)] }
        if let date { edited.date = date }
        guard !tracks.isEmpty, let medium = release.medium(for: toc),
            let index = edited.media.firstIndex(where: { $0.position == medium.position })
        else { return edited }
        let numbers = toc.audioTracks.map(\.number)
        for (position, track) in edited.media[index].tracks.enumerated() {
            guard position < numbers.count, let edit = tracks[numbers[position]] else { continue }
            var changed = track
            if let title = edit.title { changed.title = title }
            if let artist = edit.artist { changed.artistCredit = [.init(name: artist)] }
            edited.media[index].tracks[position] = changed
        }
        return edited
    }

    // MARK: disc.json

    /// The edits in a rip folder's disc.json, if it has any.
    public static func read(fromDiscJSONOf folder: URL) -> MetadataEdits? {
        let url = folder.appending(path: "disc.json")
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let edits = object["edits"]
        else { return nil }
        return try? JSONDecoder().decode(MetadataEdits.self, from: JSONSerialization.data(withJSONObject: edits))
    }

    /// Sets "edits" in a folder's disc.json (removes it when there are none), and keeps every other key.
    public func save(inDiscJSONOf folder: URL) throws {
        let url = folder.appending(path: "disc.json")
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

/// The album-level edits for each release, by MusicBrainz release ID, in a JSON file next
/// to the drive profiles. An edit made on one disc of a set applies to the others when
/// they are ripped. Rips in several drives can save at once, so a save locks the file.
public struct ReleaseEditsStore: Sendable {
    public let url: URL

    public init(url: URL = DriveProfileStore.defaultDirectory.appending(path: "ReleaseEdits.json")) {
        self.url = url
    }

    public func edits(forReleaseID releaseID: String) -> MetadataEdits? {
        load()[releaseID]
    }

    /// Keeps the album-level part of `edits` for the release; none removes the entry.
    public func remember(_ edits: MetadataEdits, forReleaseID releaseID: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = open(url.path + ".lock", O_RDWR | O_CREAT, 0o644)
        guard lock >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { close(lock) }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN) }

        var all = load()
        let album = edits.albumLevel
        all[releaseID] = album.isEmpty ? nil : album
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: url, options: .atomic)
    }

    private func load() -> [String: MetadataEdits] {
        (try? JSONDecoder().decode([String: MetadataEdits].self, from: Data(contentsOf: url))) ?? [:]
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
                title: cdText?.titles[track.number].flatMap { $0.isEmpty ? nil : $0 } ?? "Track \(track.number)",
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
