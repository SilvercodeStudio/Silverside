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
        public var composers: [String] = []
        /// The lyricists, the same way. A "writer" counts as both.
        public var lyricists: [String] = []

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
        composers = try container.decodeIfPresent([String].self, forKey: .composers) ?? []
        lyricists = try container.decodeIfPresent([String].self, forKey: .lyricists) ?? []
    }
}

/// The releases that MusicBrainz has for a disc.
public struct MusicBrainzLookup: Equatable, Sendable {
    public var releases: [MusicBrainzRelease]
    /// True if MusicBrainz knows the disc ID. False if it found the releases by a fuzzy
    /// match of the TOC: other pressings, whose track lengths are nearly the same.
    public var isExact: Bool
}

/// Looks up discs and releases in MusicBrainz, through `WebClient`: a rate limit, retries
/// on 503, and a cache, so the user's access to MusicBrainz stays safe.
public struct MusicBrainzClient: Sendable {
    public static let baseURL = URL(string: "https://musicbrainz.org/ws/2/")!

    /// What each lookup asks MusicBrainz to include: credits, labels, tracks, release groups,
    /// genres, and the relationships that name each recording's work and its composers.
    static let includes =
        "artist-credits+labels+recordings+release-groups+genres+artist-rels+work-rels+recording-level-rels+work-level-rels"

    public let client: WebClient

    public init(client: WebClient = .shared) {
        self.client = client
    }

    /// The releases with a disc that has this TOC. If MusicBrainz does not know the disc ID,
    /// the same request finds releases with nearly the same TOC.
    public func lookup(_ toc: TOC) async throws -> MusicBrainzLookup {
        guard let data = try await client.data(from: Self.lookupURL(for: toc)) else {
            return MusicBrainzLookup(releases: [], isExact: false)
        }
        return try Self.lookup(fromJSON: data)
    }

    /// One release, by its MusicBrainz ID.
    public func release(id: String) async throws -> MusicBrainzRelease? {
        var components = URLComponents(
            url: Self.baseURL.appending(path: "release/\(id)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "inc", value: Self.includes), URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let data = try await client.data(from: components.url!) else { return nil }
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
            URLQueryItem(name: "inc", value: includes),
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

private struct RawCredit: Decodable {
    struct Artist: Decodable {
        var id: String?
        var sortName: String?
        enum CodingKeys: String, CodingKey {
            case id
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
    struct Artist: Decodable { var name: String }
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
        func track(_ track: Medium.Track) -> MusicBrainzRelease.Track {
            let writers = Self.writers(track.recording?.relations)
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
    static func writers(_ relations: [RawRelation]?) -> (composers: [String], lyricists: [String]) {
        var composers = [String]()
        var lyricists = [String]()
        func add(_ relation: RawRelation) {
            guard let name = relation.artist?.name else { return }
            if ["composer", "writer"].contains(relation.type), !composers.contains(name) { composers.append(name) }
            if ["lyricist", "writer"].contains(relation.type), !lyricists.contains(name) { lyricists.append(name) }
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
