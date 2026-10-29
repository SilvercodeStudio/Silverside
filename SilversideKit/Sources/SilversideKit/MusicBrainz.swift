import Foundation

/// A MusicBrainz release, with what Silverside needs for names and tags. It is Codable in
/// Silverside's own form, so `disc.json` can keep it, and a rip can be tagged with no network.
public struct MusicBrainzRelease: Codable, Equatable, Sendable {
    /// One part of an artist credit, such as "Grateful Dead" or "Bob Dylan" + " & ".
    public struct Credit: Codable, Equatable, Sendable {
        public var name: String
        public var joinPhrase: String
        public var artistID: String?
        public var sortName: String?

        public init(name: String, joinPhrase: String = "", artistID: String? = nil, sortName: String? = nil) {
            self.name = name
            self.joinPhrase = joinPhrase
            self.artistID = artistID
            self.sortName = sortName
        }
    }

    /// A composer or lyricist, from MusicBrainz's relationships: the artist's name as
    /// MusicBrainz has it (in its own script), and the name in the user's language when
    /// MusicBrainz has an alias for it. Tags take the user's language; the report keeps both.
    public struct Writer: Codable, Equatable, Sendable {
        public var name: String
        public var localeName: String?
        public var sortName: String?

        public init(name: String, localeName: String? = nil, sortName: String? = nil) {
            self.name = name
            self.localeName = localeName
            self.sortName = sortName
        }

        /// The name for tags: in the user's language when MusicBrainz has it.
        public var tagName: String { localeName ?? name }

        /// Both names for people, "Aram Khachaturian (Արամ Խաչատրյան)", when they differ.
        public var shownName: String { localeName.map { "\($0) (\(name))" } ?? name }

        // A release saved on 2026-10-23 has a writer as its name alone.
        public init(from decoder: any Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self.init(name: name)
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                name: try container.decode(String.self, forKey: .name),
                localeName: try container.decodeIfPresent(String.self, forKey: .localeName),
                sortName: try container.decodeIfPresent(String.self, forKey: .sortName))
        }
    }

    public struct Track: Codable, Equatable, Sendable {
        /// The track's position on its medium, from 1.
        public var position: Int
        /// The number printed on the release, such as "3" or "A3".
        public var number: String
        public var title: String
        /// The length in milliseconds, if MusicBrainz has it.
        public var length: Int?
        public var artistCredit: [Credit]
        public var recordingID: String?
        /// The composers of the recording's work, from MusicBrainz's relationships, in its order.
        /// Empty when MusicBrainz lists none, and in releases saved before Silverside kept them.
        public var composers: [Writer] = []
        /// The lyricists, the same way. A "writer" counts as both.
        public var lyricists: [Writer] = []

        public var artist: String { MusicBrainzRelease.joined(artistCredit) }
    }

    /// One disc (or other medium) of a release.
    public struct Medium: Codable, Equatable, Sendable {
        public var position: Int
        public var format: String?
        /// The medium's own title, for example "Disc 2: Encores", if it has one.
        public var title: String?
        /// The disc IDs that MusicBrainz knows for this medium: one for each pressing whose TOC differs.
        public var discIDs: [String]
        public var tracks: [Track]
        /// The track before track 1 (hidden track one audio), if MusicBrainz lists one: position 0.
        public var hiddenTrack: Track?
    }

    public struct Label: Codable, Equatable, Sendable {
        public var name: String?
        public var catalogNumber: String?
    }

    public struct ReleaseGroup: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        /// "Album", "Single", and so on.
        public var primaryType: String?
        public var secondaryTypes: [String]
        public var firstReleaseDate: String?
    }

    public var id: String
    public var title: String
    public var artistCredit: [Credit]
    /// The date, as precise as MusicBrainz has it: "1977", "1977-05", or "2017-05-05".
    public var date: String?
    /// The country code, such as "US", or "XE" for Europe and "XW" for worldwide.
    public var country: String?
    /// "Official", "Bootleg", and so on.
    public var status: String?
    /// The barcode (UPC or EAN), as printed. Empty if the release has none.
    public var barcode: String?
    public var disambiguation: String?
    public var labels: [Label]
    public var releaseGroup: ReleaseGroup?
    public var media: [Medium]
    /// True if the Cover Art Archive has a front cover for the release.
    public var hasFrontCover: Bool
    /// The number of images that the Cover Art Archive has for the release: front, back,
    /// booklet pages, and others. Nil in releases saved before Silverside kept it.
    public var artworkCount: Int?

    /// True if the Cover Art Archive may have images for the release: a front cover, or any
    /// image (in releases saved before the count was kept, any release MusicBrainz knows).
    public var hasArtwork: Bool { !isManual && (hasFrontCover || (artworkCount ?? 1) > 0) }

    /// The release's page in MusicBrainz. Nil for a manual release.
    public var pageURL: URL? { isManual ? nil : URL(string: "https://musicbrainz.org/release/\(id)") }

    /// True if every medium is a plain CD: no DVD or Blu-ray, and no HDCD or other kind of CD.
    public var isCDsOnly: Bool { media.allSatisfy { $0.format == "CD" } }

    /// The media as MusicBrainz shows them: "CD", "2×CD", "CD + Blu-ray".
    public var formats: String {
        var counts = [(format: String, count: Int)]()
        for medium in media {
            let format = medium.format ?? "(unknown)"
            if let index = counts.firstIndex(where: { $0.format == format }) {
                counts[index].count += 1
            } else {
                counts.append((format, 1))
            }
        }
        return counts.map { $0.count > 1 ? "\($0.count)×\($0.format)" : $0.format }.joined(separator: " + ")
    }
    /// The genre with the most votes in MusicBrainz, from the release group, else the release:
    /// "Rock", "Jazz". Nil when there are no votes, and in releases saved before Silverside kept it.
    public var genre: String?

    public var artist: String { Self.joined(artistCredit) }

    /// The medium with the disc ID, if the release has it.
    public func medium(withDiscID discID: String) -> Medium? {
        media.first { $0.discIDs.contains(discID) }
    }

    /// The medium that holds the disc with this TOC: the one with its disc ID, else the one
    /// whose tracks have the TOC's number and lengths. A fuzzy match has no disc ID, and a
    /// set's discs must not get the same medium. Nil if no medium has that many tracks, or
    /// if two fit equally well (as when their lengths are not known).
    public func medium(for toc: TOC) -> Medium? {
        if let medium = medium(withDiscID: toc.musicBrainzDiscID) { return medium }
        let lengths = toc.audioTracks.map { toc.sectorRange(of: $0).count * 1000 / CDDA.sectorsPerSecond }
        let candidates = media.filter { $0.tracks.count == lengths.count }
        guard candidates.count > 1 else { return candidates.first }
        // The total difference in track lengths, in milliseconds; unknown lengths count as far.
        func distance(_ medium: Medium) -> Int {
            zip(medium.tracks, lengths).reduce(0) { total, pair in
                total + (pair.0.length.map { abs($0 - pair.1) } ?? 3_600_000)
            }
        }
        let ranked = candidates.map { ($0, distance($0)) }.sorted { $0.1 < $1.1 }
        // The best must be better than the next by a second for each track, or it is a guess.
        guard ranked[1].1 - ranked[0].1 >= 1000 * lengths.count else { return nil }
        return ranked[0].0
    }

    /// True if MusicBrainz gave this release for the disc without the disc's ID: a match of
    /// the track lengths, as for a release no one has added the disc ID to (`submissionURL`).
    /// False for a manual release, which is not MusicBrainz's.
    public func lacksDiscID(of toc: TOC) -> Bool {
        !isManual && medium(withDiscID: toc.musicBrainzDiscID) == nil
    }

    /// The page where a user can add this disc ID to a release in MusicBrainz.
    public static func submissionURL(for toc: TOC) -> URL {
        var components = URLComponents(string: "https://musicbrainz.org/cdtoc/attach")!
        components.queryItems = [
            URLQueryItem(name: "id", value: toc.musicBrainzDiscID),
            URLQueryItem(name: "tracks", value: String(toc.audioTracks.count)),
            URLQueryItem(name: "toc", value: toc.musicBrainzTOCString.replacingOccurrences(of: "+", with: " ")),
        ]
        return components.url!
    }

    static func joined(_ credit: [Credit]) -> String {
        credit.map { $0.name + $0.joinPhrase }.joined()
    }

    /// The credit's sort name, "Dead, Grateful", for the ARTISTSORT tags. Nil when MusicBrainz
    /// gave no sort name for any of its artists (a disc it does not know, or an edited name).
    public static func sortName(_ credit: [Credit]) -> String? {
        guard credit.contains(where: { $0.sortName != nil }) else { return nil }
        return credit.map { ($0.sortName ?? $0.name) + $0.joinPhrase }.joined()
    }
}

extension MusicBrainzRelease.Track {
    // Releases saved before Silverside kept composers and lyricists have none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decode(Int.self, forKey: .position)
        number = try container.decode(String.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        length = try container.decodeIfPresent(Int.self, forKey: .length)
        artistCredit = try container.decode([MusicBrainzRelease.Credit].self, forKey: .artistCredit)
        recordingID = try container.decodeIfPresent(String.self, forKey: .recordingID)
        composers = try container.decodeIfPresent([MusicBrainzRelease.Writer].self, forKey: .composers) ?? []
        lyricists = try container.decodeIfPresent([MusicBrainzRelease.Writer].self, forKey: .lyricists) ?? []
    }
}

/// The releases that MusicBrainz has for a disc.
public struct MusicBrainzLookup: Equatable, Sendable {
    public var releases: [MusicBrainzRelease]
    /// True if MusicBrainz knows the disc ID. False if it found the releases by a fuzzy
    /// match of the TOC: other pressings, whose track lengths are nearly the same.
    public var isExact: Bool

    /// The lookup without the fuzzy matches whose tracks are not the disc's. MusicBrainz's
    /// fuzzy match goes by the number of tracks and about the disc's length, so a 20-track
    /// compilation of 80 minutes matches others with nothing in common (*KUTX Live! Volume 3*:
    /// *Formel Eins: Boys Edition* and seven more). A release stays if a disc of it has each
    /// track within 3 seconds of this disc's (`ReleaseRanking.fits`), as another pressing has.
    public func fitting(_ toc: TOC) -> MusicBrainzLookup {
        guard !isExact else { return self }
        let fitting = releases.filter { release in release.media.contains { ReleaseRanking.fits($0, toc: toc) } }
        return MusicBrainzLookup(releases: fitting, isExact: false)
    }
}

/// Looks up discs and releases in MusicBrainz, through `WebClient`: a rate limit, retries
/// on 503, and a cache, so the user's access to MusicBrainz stays safe.
public struct MusicBrainzClient: Sendable {
    public static let baseURL = URL(string: "https://musicbrainz.org/ws/2/")!

    /// What a disc lookup asks MusicBrainz to include: credits, labels, tracks, release groups,
    /// and genres. The disc ID resource refuses the recording-level relationships.
    static let discIncludes = "artist-credits+labels+recordings+release-groups+genres"

    /// What a release lookup includes: the same, the disc IDs, and the relationships that name
    /// each recording's work and its composers (`work-level-rels` is only for a release lookup).
    static let releaseIncludes =
        discIncludes + "+discids+aliases+artist-rels+work-rels+recording-level-rels+work-level-rels"

    public let client: WebClient

    public init(client: WebClient = .shared) {
        self.client = client
    }

    /// The releases with a disc that has this TOC. If MusicBrainz does not know the disc ID,
    /// the same request finds releases with nearly the same TOC; only those whose tracks fit
    /// the disc are kept (`MusicBrainzLookup.fitting`). `useCache: false` asks again, for a
    /// disc just added to MusicBrainz: the cache keeps a "not found" for a day.
    public func lookup(_ toc: TOC, useCache: Bool = true) async throws -> MusicBrainzLookup {
        guard let data = try await client.data(from: Self.lookupURL(for: toc), useCache: useCache) else {
            return MusicBrainzLookup(releases: [], isExact: false)
        }
        return try Self.lookup(fromJSON: data).fitting(toc)
    }

    /// The releases with this disc from an earlier lookup in the cache, with no request; nil if
    /// the disc was never looked up (or MusicBrainz did not know it).
    public func cachedLookup(_ toc: TOC) -> MusicBrainzLookup? {
        client.cachedData(from: Self.lookupURL(for: toc)).flatMap { try? Self.lookup(fromJSON: $0).fitting(toc) }
    }

    /// One release, by its MusicBrainz ID, with its recordings' relationships: the composers.
    public func release(id: String, useCache: Bool = true) async throws -> MusicBrainzRelease? {
        guard let data = try await client.data(from: Self.releaseURL(id: id), useCache: useCache) else { return nil }
        return try Self.release(fromJSON: data)
    }

    static func releaseURL(id: String) -> URL {
        var components = URLComponents(
            url: baseURL.appending(path: "release/\(id)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "inc", value: releaseIncludes), URLQueryItem(name: "fmt", value: "json"),
        ]
        return components.url!
    }

    /// Parses a release lookup.
    public static func release(fromJSON data: Data) throws -> MusicBrainzRelease {
        do {
            return try JSONDecoder().decode(RawRelease.self, from: data).release
        } catch {
            throw MusicBrainzError.malformedResponse
        }
    }

    static func lookupURL(for toc: TOC) -> URL {
        var components = URLComponents(
            url: baseURL.appending(path: "discid/\(toc.musicBrainzDiscID)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "toc", value: toc.musicBrainzTOCString),
            URLQueryItem(name: "cdstubs", value: "no"),
            URLQueryItem(name: "inc", value: discIncludes),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        return components.url!
    }

    /// Parses a disc ID lookup. An exact match is a disc, with an `id`; a fuzzy match is a list of releases.
    public static func lookup(fromJSON data: Data) throws -> MusicBrainzLookup {
        do {
            let raw = try JSONDecoder().decode(RawLookup.self, from: data)
            return MusicBrainzLookup(releases: raw.releases.map(\.release), isExact: raw.id != nil)
        } catch {
            throw MusicBrainzError.malformedResponse
        }
    }
}

public enum MusicBrainzError: Error, Equatable {
    case malformedResponse
}

extension TOC {
    /// The TOC as MusicBrainz takes it for a fuzzy lookup: the first and last track numbers,
    /// the lead-out, then each track's start, all with the 150-sector lead-in. As for the
    /// disc ID, the data track of an enhanced CD is left out.
    public var musicBrainzTOCString: String {
        let idTracks = isEnhanced ? tracks.dropLast() : tracks[...]
        let values =
            [idTracks.first!.number, idTracks.last!.number, audioLeadOutLBA + CDDA.leadInSectors]
            + idTracks.map { $0.startLBA + CDDA.leadInSectors }
        return values.map(String.init).joined(separator: "+")
    }
}

// MusicBrainz's JSON, with only the fields Silverside uses.

private struct RawLookup: Decodable {
    var id: String?
    var releases: [RawRelease]
}

/// An artist's name in a language, from `inc=aliases`.
private struct RawAlias: Decodable {
    var name: String
    var locale: String?
    var primary: Bool?
    var type: String?

    /// The alias in the user's language: a primary artist name first.
    static func localeName(in aliases: [RawAlias]) -> String? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let candidates = aliases.filter { $0.locale == language || $0.locale?.hasPrefix(language + "_") == true }
        return
            (candidates.first { $0.primary == true && $0.type == "Artist name" }
            ?? candidates.first { $0.primary == true } ?? candidates.first)?.name
    }
}

private struct RawCredit: Decodable {
    struct Artist: Decodable {
        var id: String?
        var sortName: String?
        var aliases: [RawAlias]?
        enum CodingKeys: String, CodingKey {
            case id, aliases
            case sortName = "sort-name"
        }
    }
    var name: String
    var joinphrase: String?
    var artist: Artist?

    var credit: MusicBrainzRelease.Credit {
        .init(name: name, joinPhrase: joinphrase ?? "", artistID: artist?.id, sortName: artist?.sortName)
    }
}

/// A relationship of a recording or a work: to a work ("performance") or to an artist ("composer").
private struct RawRelation: Decodable {
    struct Artist: Decodable {
        var id: String?
        var name: String
        var sortName: String?
        var aliases: [RawAlias]?
        enum CodingKeys: String, CodingKey {
            case id, name, aliases
            case sortName = "sort-name"
        }

        /// The artist as a writer: with the alias in the user's language when the name is in
        /// another script, as MusicBrainz Picard translates names. A Latin name stays as it is.
        /// MusicBrainz sends no aliases with an artist in a relationship (seen 2026-10-23), so
        /// `credited` has the aliases of the release's and the tracks' credited artists, by ID.
        func writer(credited: [String: [RawAlias]]) -> MusicBrainzRelease.Writer {
            var localeName: String?
            if !Self.isLatin(name) {
                let aliases = (self.aliases ?? []) + (id.flatMap { credited[$0] } ?? [])
                localeName = RawAlias.localeName(in: aliases)
            }
            return .init(name: name, localeName: localeName, sortName: sortName)
        }

        /// True when every letter is Latin: ASCII, Latin-1, the Latin Extended blocks.
        static func isLatin(_ text: String) -> Bool {
            text.unicodeScalars.allSatisfy { scalar in
                !scalar.properties.isAlphabetic || scalar.value < 0x0250 || (0x1E00...0x1EFF).contains(scalar.value)
            }
        }
    }
    struct Work: Decodable { var relations: [RawRelation]? }
    var type: String
    var artist: Artist?
    var work: Work?
}

private struct RawGenre: Decodable {
    var name: String
    var count: Int?
}

private struct RawRelease: Decodable {
    struct LabelInfo: Decodable {
        struct Label: Decodable { var name: String? }
        var catalogNumber: String?
        var label: Label?
        enum CodingKeys: String, CodingKey {
            case catalogNumber = "catalog-number"
            case label
        }
    }
    struct Group: Decodable {
        var id: String
        var title: String
        var primaryType: String?
        var secondaryTypes: [String]?
        var firstReleaseDate: String?
        var genres: [RawGenre]?
        enum CodingKeys: String, CodingKey {
            case id, title, genres
            case primaryType = "primary-type"
            case secondaryTypes = "secondary-types"
            case firstReleaseDate = "first-release-date"
        }
    }
    struct Medium: Decodable {
        struct Disc: Decodable { var id: String }
        struct Track: Decodable {
            struct Recording: Decodable {
                var id: String
                var relations: [RawRelation]?
            }
            var position: Int
            var number: String?
            var title: String
            var length: Int?
            var artistCredit: [RawCredit]?
            var recording: Recording?
            enum CodingKeys: String, CodingKey {
                case position, number, title, length, recording
                case artistCredit = "artist-credit"
            }
        }
        var position: Int
        var format: String?
        var title: String?
        var discs: [Disc]?
        var tracks: [Track]?
        var pregap: Track?
    }
    struct CoverArt: Decodable {
        var front: Bool?
        var count: Int?
    }

    var id: String
    var title: String
    var artistCredit: [RawCredit]?
    var date: String?
    var country: String?
    var status: String?
    var barcode: String?
    var disambiguation: String?
    var labelInfo: [LabelInfo]?
    var releaseGroup: Group?
    var media: [Medium]?
    var coverArtArchive: CoverArt?
    var genres: [RawGenre]?

    enum CodingKeys: String, CodingKey {
        case id, title, date, country, status, barcode, disambiguation, media, genres
        case artistCredit = "artist-credit"
        case labelInfo = "label-info"
        case releaseGroup = "release-group"
        case coverArtArchive = "cover-art-archive"
    }

    var release: MusicBrainzRelease {
        let releaseCredit = (artistCredit ?? []).map(\.credit)
        // The credited artists' aliases, for the writers in relationships, which come without.
        var credited = [String: [RawAlias]]()
        let credits =
            (artistCredit ?? []) + (media ?? []).flatMap { ($0.tracks ?? []).flatMap { $0.artistCredit ?? [] } }
        for credit in credits {
            if let id = credit.artist?.id, let aliases = credit.artist?.aliases, !aliases.isEmpty {
                credited[id] = aliases
            }
        }
        func track(_ track: Medium.Track) -> MusicBrainzRelease.Track {
            let writers = Self.writers(track.recording?.relations, credited: credited)
            return .init(
                position: track.position, number: track.number ?? String(track.position), title: track.title,
                length: track.length, artistCredit: track.artistCredit.map { $0.map(\.credit) } ?? releaseCredit,
                recordingID: track.recording?.id, composers: writers.composers, lyricists: writers.lyricists)
        }
        return MusicBrainzRelease(
            id: id, title: title, artistCredit: releaseCredit, date: date.flatMap { $0.isEmpty ? nil : $0 },
            country: country, status: status, barcode: barcode,
            disambiguation: disambiguation.flatMap { $0.isEmpty ? nil : $0 },
            labels: (labelInfo ?? []).map { .init(name: $0.label?.name, catalogNumber: $0.catalogNumber) },
            releaseGroup: releaseGroup.map {
                .init(
                    id: $0.id, title: $0.title, primaryType: $0.primaryType, secondaryTypes: $0.secondaryTypes ?? [],
                    firstReleaseDate: $0.firstReleaseDate)
            },
            media: (media ?? []).map { medium in
                .init(
                    position: medium.position, format: medium.format,
                    title: medium.title.flatMap { $0.isEmpty ? nil : $0 }, discIDs: (medium.discs ?? []).map(\.id),
                    tracks: (medium.tracks ?? []).map(track), hiddenTrack: medium.pregap.map(track))
            },
            hasFrontCover: coverArtArchive?.front ?? false, artworkCount: coverArtArchive?.count,
            genre: Self.topGenre([releaseGroup?.genres, genres]))
    }

    /// The composers and lyricists of a recording: from the works it performs (their
    /// relationships name the writers), and from its own relationships. A "writer" is both.
    static func writers(_ relations: [RawRelation]?, credited: [String: [RawAlias]]) -> (
        composers: [MusicBrainzRelease.Writer], lyricists: [MusicBrainzRelease.Writer]
    ) {
        var composers = [MusicBrainzRelease.Writer]()
        var lyricists = [MusicBrainzRelease.Writer]()
        func add(_ relation: RawRelation) {
            guard let writer = relation.artist?.writer(credited: credited) else { return }
            if ["composer", "writer"].contains(relation.type), !composers.contains(where: { $0.name == writer.name }) {
                composers.append(writer)
            }
            if ["lyricist", "writer"].contains(relation.type), !lyricists.contains(where: { $0.name == writer.name }) {
                lyricists.append(writer)
            }
        }
        for relation in relations ?? [] {
            if let work = relation.work {
                work.relations?.forEach(add)
            } else {
                add(relation)
            }
        }
        return (composers, lyricists)
    }

    /// The genre with the most votes in the first list that has any, as "Rock" or "Hip Hop".
    static func topGenre(_ lists: [[RawGenre]?]) -> String? {
        for list in lists {
            guard let best = list?.max(by: { ($0.count ?? 0) < ($1.count ?? 0) }) else { continue }
            return best.name.capitalized
        }
        return nil
    }
}
