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

extension MusicBrainzClient {
    /// Searches MusicBrainz's releases (`/ws/2/release?query=`), the best match first. `text` is
    /// what the user typed (`searchQuery(for:)`). The answer is cached like any other.
    public func searchReleases(_ text: String, limit: Int = 25, useCache: Bool = true) async throws
        -> [MusicBrainzSearchResult]
    {
        let query = Self.searchQuery(for: text)
        guard !query.isEmpty,
            let data = try await client.data(from: Self.searchURL(query: query, limit: limit), useCache: useCache)
        else { return [] }
        return try Self.searchResults(fromJSON: data)
    }

    /// The query for what the user typed. Words go as they are, and MusicBrainz looks for them
    /// in the title, the artist, the label, and so on ("dave brubeck seven classic lps" finds
    /// the box first); characters that the query language uses are escaped. A barcode (12 or 13
    /// digits) is looked for as a barcode, with and without its leading 0, as MusicBrainz may
    /// keep a UPC or an EAN. A query that names a field ("catno:EN4CD9161") goes as it is; a
    /// title such as "Soundtracks: Vol. 1" or "Classic Country: Hits" does not name one.
    public static func searchQuery(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let barcode = barcodeQuery(for: trimmed) { return barcode }
        let field = /(^|[\s(])(release|artist|barcode|catno|label|date|country|format|tracks):[^\s]/
        if trimmed.lowercased().contains(field) { return trimmed }
        let special = Set("+-&|!(){}[]^\"~*?:\\/")
        return String(trimmed.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    /// The query for a barcode: "barcode:0823564030142 OR barcode:823564030142". Nil if `text`
    /// is not 12 or 13 digits, or is all zeros (a disc's MCN when it has none).
    public static func barcodeQuery(for text: String) -> String? {
        guard (12...13).contains(text.count), text.allSatisfy(\.isASCIIDigit), text.contains(where: { $0 != "0" })
        else { return nil }
        let forms = [text, text.count == 13 && text.hasPrefix("0") ? String(text.dropFirst()) : "0" + text]
        return Array(Set(forms)).sorted().map { "barcode:\($0)" }.joined(separator: " OR ")
    }

    static func searchURL(query: String, limit: Int) -> URL {
        var components = URLComponents(url: baseURL.appending(path: "release"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "query", value: query), URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        // URLComponents leaves "+" as it is, and the server reads it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// Parses a release search.
    public static func searchResults(fromJSON data: Data) throws -> [MusicBrainzSearchResult] {
        do {
            return try JSONDecoder().decode(RawSearch.self, from: data).releases.map(\.result)
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
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
