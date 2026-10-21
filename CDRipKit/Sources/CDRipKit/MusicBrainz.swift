import Foundation

/// A MusicBrainz release, with what CDRip needs for names and tags. It is Codable in
/// CDRip's own form, so `disc.json` can keep it, and a rip can be tagged with no network.
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
    /// booklet pages, and others. Nil in releases saved before CDRip kept it.
    public var artworkCount: Int?

    public var artist: String { Self.joined(artistCredit) }

    /// The medium with the disc ID, if the release has it.
    public func medium(withDiscID discID: String) -> Medium? {
        media.first { $0.discIDs.contains(discID) }
    }

    static func joined(_ credit: [Credit]) -> String {
        credit.map { $0.name + $0.joinPhrase }.joined()
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

    /// What each lookup asks MusicBrainz to include: credits, labels, tracks, and release groups.
    static let includes = "artist-credits+labels+recordings+release-groups"

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

// MusicBrainz's JSON, with only the fields CDRip uses.

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
        enum CodingKeys: String, CodingKey {
            case id, title
            case primaryType = "primary-type"
            case secondaryTypes = "secondary-types"
            case firstReleaseDate = "first-release-date"
        }
    }
    struct Medium: Decodable {
        struct Disc: Decodable { var id: String }
        struct Track: Decodable {
            struct Recording: Decodable { var id: String }
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

    enum CodingKeys: String, CodingKey {
        case id, title, date, country, status, barcode, disambiguation, media
        case artistCredit = "artist-credit"
        case labelInfo = "label-info"
        case releaseGroup = "release-group"
        case coverArtArchive = "cover-art-archive"
    }

    var release: MusicBrainzRelease {
        let releaseCredit = (artistCredit ?? []).map(\.credit)
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
                    tracks: (medium.tracks ?? []).map { track in
                        .init(
                            position: track.position, number: track.number ?? String(track.position),
                            title: track.title,
                            length: track.length,
                            artistCredit: track.artistCredit.map { $0.map(\.credit) } ?? releaseCredit,
                            recordingID: track.recording?.id)
                    })
            },
            hasFrontCover: coverArtArchive?.front ?? false, artworkCount: coverArtArchive?.count)
    }
}
