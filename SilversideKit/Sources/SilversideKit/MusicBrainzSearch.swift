import Foundation

/// One release that a MusicBrainz search found: what tells releases apart, and the track count
/// of each disc, to see whether a disc fits. A search gives no tracks; the release looked up by
/// its ID has them (`MusicBrainzClient.release(id:)`).
public struct MusicBrainzSearchResult: Equatable, Identifiable, Sendable {
    public struct Medium: Equatable, Sendable {
        public var format: String?
        public var trackCount: Int
    }

    public var id: String
    /// MusicBrainz's score for the match, 0 to 100.
    public var score: Int
    public var title: String
    public var artist: String
    public var date: String?
    public var country: String?
    public var barcode: String?
    public var status: String?
    public var disambiguation: String?
    /// "Enlightenment EN4CD9161", for each label.
    public var labels: [String]
    /// The release's media, in order.
    public var media: [Medium]
    public var releaseGroupID: String?

    /// The positions of the discs with `count` tracks: the discs that a disc with that many tracks can be.
    public func positions(withTrackCount count: Int) -> [Int] {
        media.enumerated().filter { $0.element.trackCount == count }.map { $0.offset + 1 }
    }

    /// "4×CD", "CD + DVD-Video": the media, as MusicBrainz shows them.
    public var formats: String {
        var groups = [(format: String, count: Int)]()
        for medium in media {
            let format = medium.format ?? "(unknown)"
            if let last = groups.last, last.format == format {
                groups[groups.count - 1].count += 1
            } else {
                groups.append((format, 1))
            }
        }
        return groups.map { $0.count > 1 ? "\($0.count)×\($0.format)" : $0.format }.joined(separator: " + ")
    }
}

extension MusicBrainzSearchResult {
    /// A release looked up by its ID, as a search lists it: the release of a link that the
    /// user pasted.
    public init(release: MusicBrainzRelease) {
        func given(_ text: String?) -> String? { text.flatMap { $0.isEmpty ? nil : $0 } }
        self.init(
            id: release.id, score: 100, title: release.title, artist: release.artist, date: given(release.date),
            country: release.country, barcode: given(release.barcode), status: release.status,
            disambiguation: given(release.disambiguation),
            labels: release.labels.map { [$0.name, $0.catalogNumber].compactMap { $0 }.joined(separator: " ") }
                .filter { !$0.isEmpty },
            media: release.media.map { Medium(format: $0.format, trackCount: $0.tracks.count) },
            releaseGroupID: release.releaseGroup?.id)
    }
}

/// One page of a release search: its results, where they start, and how many releases match in
/// all. A search asks for one page, and the user for each page after it, up to `mostResults`.
public struct MusicBrainzSearchPage: Equatable, Sendable {
    /// The results in one page.
    public static let size = 25
    /// The results a search goes to at most: 4 pages, each one asked for. A release further down
    /// is found by more words, its barcode, or its link.
    public static let mostResults = 100

    public var results: [MusicBrainzSearchResult]
    /// The place of the first result in the whole search, from 0.
    public var offset: Int
    /// The releases that match in all; MusicBrainz counts every one that has any of the words.
    public var total: Int

    public init(results: [MusicBrainzSearchResult], offset: Int = 0, total: Int) {
        self.results = results
        self.offset = offset
        self.total = total
    }

    /// Where the next page starts, or nil when there is none: MusicBrainz has no more, or the
    /// search has its most.
    public var nextOffset: Int? {
        let next = offset + results.count
        return !results.isEmpty && next < total && next < Self.mostResults ? next : nil
    }
}

/// A release search as MusicBrainz takes it (`MusicBrainzClient.searchQuery(for:)`).
public struct MusicBrainzSearchQuery: Equatable, Sendable {
    /// The query, in MusicBrainz's query language unless `isPlain`.
    public var text: String
    /// `text` is plain words, which MusicBrainz looks for in each release's title and artist,
    /// each word counted once, where it fits best, as the search on its website does
    /// (`dismax=true`, which escapes the language's characters itself). It does not look in
    /// catalog numbers.
    public var isPlain: Bool

    public init(_ text: String, isPlain: Bool = false) {
        self.text = text
        self.isPlain = isPlain
    }
}

/// What a link to MusicBrainz that the user pasted names (`MusicBrainzClient.link(in:)`).
public enum MusicBrainzLink: Equatable, Sendable {
    case release(String)
    case releaseGroup(String)
    /// Another page of MusicBrainz, such as an artist's: no release to search for.
    case other
}

extension MusicBrainzClient {
    /// Searches MusicBrainz's releases (`/ws/2/release?query=`), the best match first. `text` is
    /// what the user typed (`searchQuery(for:)`). The answer is cached like any other. A link to
    /// a release, or its ID, gives that release, looked up by its ID: the search's index can be
    /// behind a release added minutes ago, and the lookup is the one that choosing it makes.
    public func searchReleases(_ text: String, limit: Int = MusicBrainzSearchPage.size, useCache: Bool = true)
        async throws -> [MusicBrainzSearchResult]
    {
        try await searchReleasePage(text, limit: limit, useCache: useCache).results
    }

    /// One page of `searchReleases`: `limit` results from `offset`, with the number that match
    /// in all, for a search that the user takes further. Each page is a request of its own.
    public func searchReleasePage(
        _ text: String, offset: Int = 0, limit: Int = MusicBrainzSearchPage.size, useCache: Bool = true
    ) async throws -> MusicBrainzSearchPage {
        if case .release(let id) = Self.link(in: text) {
            let found = try await release(id: id, useCache: useCache).map { [MusicBrainzSearchResult(release: $0)] }
            return MusicBrainzSearchPage(results: found ?? [], total: found?.count ?? 0)
        }
        let query = Self.searchQuery(for: text)
        guard !query.text.isEmpty,
            let data = try await client.data(
                from: Self.searchURL(query: query, limit: limit, offset: offset), useCache: useCache)
        else { return MusicBrainzSearchPage(results: [], offset: offset, total: 0) }
        return try Self.searchPage(fromJSON: data)
    }

    /// The fields of MusicBrainz's release search. Text that names one, with no space after
    /// the colon ("catno:EN4CD9161", "comment:(bonus)"), is a query in its language.
    static let releaseFields = [
        "alias", "arid", "artist", "artistname", "asin", "barcode", "catno", "comment", "country", "creditname",
        "date", "discids", "discidsmedium", "format", "laid", "label", "lang", "mediums", "primarytype", "quality",
        "reid", "release", "releaseaccent", "rgid", "script", "secondarytype", "status", "tag", "tracks",
        "tracksmedium", "type",
    ]

    /// The query for what the user typed:
    ///
    /// - A link to a release or a release group looks for it by its ID; a link to another page
    ///   of MusicBrainz looks for nothing.
    /// - A barcode (12 or 13 digits) is looked for as a barcode, with and without its leading 0,
    ///   as MusicBrainz may keep a UPC or an EAN.
    /// - Text that names a field (`releaseFields`) goes as it is. A title such as "Soundtracks:
    ///   Vol. 1" or "Classic Country: Hits" names none.
    /// - Text that can be a catalog number, a digit in at most 3 words ("CK 67862",
    ///   "EN4CD9161"), is looked for as one, ahead of the title and the artist. MusicBrainz keeps
    ///   a catalog number as one word without its spaces, so the spaces are escaped, and its
    ///   matches count for little, so it gets 20 times the weight.
    /// - Other text is plain words (`MusicBrainzSearchQuery.isPlain`). With no field, a query
    ///   in the language looks in the title alone ("ron goodwin valhalla" found releases named
    ///   Valhalla by anyone), and words in several fields add up ("Golden Sounds of Ron Goodwin"
    ///   came before his *Valhalla*); plain words give his *Valhalla* first.
    public static func searchQuery(for text: String) -> MusicBrainzSearchQuery {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch link(in: trimmed) {
        case .release(let id): return MusicBrainzSearchQuery("reid:\(id)")
        case .releaseGroup(let id): return MusicBrainzSearchQuery("rgid:\(id)")
        case .other: return MusicBrainzSearchQuery("")
        case nil: break
        }
        if let barcode = barcodeQuery(for: trimmed) { return MusicBrainzSearchQuery(barcode) }
        let field = try? Regex("(^|[\\s(])(\(releaseFields.joined(separator: "|"))):[^\\s]")
        if let field, trimmed.lowercased().contains(field) { return MusicBrainzSearchQuery(trimmed) }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if trimmed.contains(where: \.isASCIIDigit), words.count <= 3 {
            let all = escaped(trimmed)
            let number = words.map(escaped).joined(separator: "\\ ")
            return MusicBrainzSearchQuery("catno:(\(number))^20 OR release:(\(all)) OR artist:(\(all))")
        }
        return MusicBrainzSearchQuery(trimmed, isPlain: true)
    }

    /// `text` with the characters that the query language uses escaped.
    static func escaped(_ text: String) -> String {
        let special = Set("+-&|!(){}[]^\"~*?:\\/")
        return String(text.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    /// The query for a barcode: "barcode:0823564030142 OR barcode:823564030142". Nil if `text`
    /// is not 12 or 13 digits, or is all zeros (a disc's MCN when it has none).
    public static func barcodeQuery(for text: String) -> String? {
        guard (12...13).contains(text.count), text.allSatisfy(\.isASCIIDigit), text.contains(where: { $0 != "0" })
        else { return nil }
        let forms = [text, text.count == 13 && text.hasPrefix("0") ? String(text.dropFirst()) : "0" + text]
        return Array(Set(forms)).sorted().map { "barcode:\($0)" }.joined(separator: " OR ")
    }

    /// What `text` links to: a page of MusicBrainz ("https://musicbrainz.org/release/<ID>",
    /// with or without "https://", or a page under it such as ".../discids"), or an ID alone,
    /// taken as a release's. Nil for text that is neither.
    public static func link(in text: String) -> MusicBrainzLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: trimmed) != nil { return .release(trimmed.lowercased()) }
        guard !trimmed.contains(where: \.isWhitespace),
            let url = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
            let host = url.host()?.lowercased(), host == "musicbrainz.org" || host.hasSuffix(".musicbrainz.org")
        else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        guard path.count >= 2, UUID(uuidString: path[1]) != nil else { return .other }
        let id = path[1].lowercased()
        switch path[0].lowercased() {
        case "release": return .release(id)
        case "release-group": return .releaseGroup(id)
        default: return .other
        }
    }

    static func searchURL(query: MusicBrainzSearchQuery, limit: Int, offset: Int = 0) -> URL {
        var components = URLComponents(url: baseURL.appending(path: "release"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "query", value: query.text), URLQueryItem(name: "limit", value: String(limit)),
        ]
        // A first page has no offset in its address, as before, so the cache keeps earlier searches.
        if offset > 0 { components.queryItems?.append(URLQueryItem(name: "offset", value: String(offset))) }
        if query.isPlain { components.queryItems?.append(URLQueryItem(name: "dismax", value: "true")) }
        components.queryItems?.append(URLQueryItem(name: "fmt", value: "json"))
        // URLComponents leaves "+" as it is, and the server reads it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// Parses a release search.
    public static func searchResults(fromJSON data: Data) throws -> [MusicBrainzSearchResult] {
        try searchPage(fromJSON: data).results
    }

    /// Parses a page of a release search.
    public static func searchPage(fromJSON data: Data) throws -> MusicBrainzSearchPage {
        do {
            let raw = try JSONDecoder().decode(RawSearch.self, from: data)
            let results = raw.releases.map(\.result)
            let offset = raw.offset ?? 0
            return MusicBrainzSearchPage(results: results, offset: offset, total: raw.count ?? offset + results.count)
        } catch {
            throw MusicBrainzError.malformedResponse
        }
    }
}

private struct RawSearch: Decodable {
    struct Release: Decodable {
        struct Credit: Decodable {
            var name: String
            var joinphrase: String?
        }
        struct LabelInfo: Decodable {
            struct Label: Decodable { var name: String? }
            var catalogNumber: String?
            var label: Label?
            enum CodingKeys: String, CodingKey {
                case catalogNumber = "catalog-number"
                case label
            }
        }
        struct Medium: Decodable {
            var format: String?
            var trackCount: Int?
            enum CodingKeys: String, CodingKey {
                case format
                case trackCount = "track-count"
            }
        }
        struct Group: Decodable { var id: String }

        var id: String
        var score: Int?
        var title: String
        var artistCredit: [Credit]?
        var date: String?
        var country: String?
        var barcode: String?
        var status: String?
        var disambiguation: String?
        var labelInfo: [LabelInfo]?
        var media: [Medium]?
        var releaseGroup: Group?

        enum CodingKeys: String, CodingKey {
            case id, score, title, date, country, barcode, status, disambiguation, media
            case artistCredit = "artist-credit"
            case labelInfo = "label-info"
            case releaseGroup = "release-group"
        }

        var result: MusicBrainzSearchResult {
            MusicBrainzSearchResult(
                id: id, score: score ?? 0, title: title,
                artist: (artistCredit ?? []).map { $0.name + ($0.joinphrase ?? "") }.joined(),
                date: date.flatMap { $0.isEmpty ? nil : $0 }, country: country,
                barcode: barcode.flatMap { $0.isEmpty ? nil : $0 }, status: status,
                disambiguation: disambiguation.flatMap { $0.isEmpty ? nil : $0 },
                labels: (labelInfo ?? []).map { info in
                    [info.label?.name, info.catalogNumber].compactMap { $0 }.joined(separator: " ")
                }.filter { !$0.isEmpty },
                media: (media ?? []).map { .init(format: $0.format, trackCount: $0.trackCount ?? 0) },
                releaseGroupID: releaseGroup?.id)
        }
    }

    var releases: [Release]
    var count: Int?
    var offset: Int?
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
