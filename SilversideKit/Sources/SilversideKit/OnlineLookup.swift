import Foundation

public enum OnlineLookupError: Error, Equatable, CustomStringConvertible {
    case httpStatus(Int, URL)

    public var description: String {
        switch self {
        case .httpStatus(let status, let url): "HTTP \(status) from \(url)"
        }
    }
}

extension AccurateRipRecord {
    /// Downloads the records for a disc. Returns none if the disc is not in AccurateRip.
    /// `useCache: false` asks again, for a disc that may have been added since.
    public static func download(
        for discID: AccurateRipDiscID, client: WebClient = .shared, useCache: Bool = true
    ) async throws -> [AccurateRipRecord] {
        guard let data = try await client.data(from: discID.databaseURL, useCache: useCache) else { return [] }
        return try records(from: [UInt8](data))
    }
}

/// One entry from the CUETools DB: the checksums that one group of matching submissions agree on.
public struct CTDBEntry: Equatable, Sendable {
    public var id: Int
    /// The number of submissions that agree.
    public var confidence: Int
    /// The CRC32 of the whole disc.
    public var crc32: UInt32
    public var trackCRCs: [UInt32]
    /// Where CTDB keeps the entry's repair data, if it has any.
    public var repairDataURL: URL?
    /// The number of syndromes for each column in the repair data (8 or 16).
    public var syndromeCount: Int
    /// The syndromes of column 0, from the lookup, for finding the shift between a rip and the entry.
    public var column0Syndromes: [UInt16]

    /// True if CTDB has repair data, which can correct a damaged rip.
    public var hasParity: Bool { repairDataURL != nil }

    /// Downloads the entry's repair data, in the order that `CTDB.syndromes(of:layout:shift:count:)` gives.
    public func downloadRepairData(client: WebClient = .shared) async throws -> [UInt16] {
        guard let url = repairDataURL, let data = try await client.data(from: url),
            let syndromes = CTDB.syndromes(fromRepairData: [UInt8](data), count: syndromeCount)
        else { throw CTDBError.malformedResponse }
        return syndromes
    }

    /// Looks up a disc by its TOC. Returns none if the disc is not in CTDB. `useCache: false`
    /// asks again, for a disc that may have been added since.
    public static func lookup(_ toc: TOC, client: WebClient = .shared, useCache: Bool = true) async throws
        -> [CTDBEntry]
    {
        var components = URLComponents(string: "http://db.cuetools.net/lookup2.php")!
        components.queryItems = [
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "ctdb", value: "1"),
            URLQueryItem(name: "fuzzy", value: "0"),
            URLQueryItem(name: "toc", value: toc.ctdbTOCString),
        ]
        guard let data = try await client.data(from: components.url!, useCache: useCache) else { return [] }
        return try entries(fromXML: data)
    }

    /// Parses a CTDB lookup response.
    public static func entries(fromXML data: Data) throws(CTDBError) -> [CTDBEntry] {
        let reader = EntryReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), !reader.isMalformed else { throw .malformedResponse }
        return reader.entries
    }

    private final class EntryReader: NSObject, XMLParserDelegate {
        var entries = [CTDBEntry]()
        var isMalformed = false

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            guard name == "entry" else { return }
            guard let id = attributes["id"].flatMap({ Int($0) }),
                let confidence = attributes["confidence"].flatMap({ Int($0) }),
                let crc32 = attributes["crc32"].flatMap({ UInt32($0, radix: 16) })
            else {
                isMalformed = true
                return
            }
            let trackCRCs = (attributes["trackcrcs"] ?? "").split(separator: " ").compactMap { UInt32($0, radix: 16) }
            let syndromeCount = attributes["npar"].flatMap { Int($0) } ?? 0
            let syndromeBytes = attributes["syndrome"].flatMap { Data(base64Encoded: $0) }.map { [UInt8]($0) } ?? []
            let column0 = stride(from: 0, to: syndromeBytes.count - 1, by: 2).map {
                UInt16(syndromeBytes[$0]) | UInt16(syndromeBytes[$0 + 1]) << 8
            }
            entries.append(
                CTDBEntry(
                    id: id, confidence: confidence, crc32: crc32, trackCRCs: trackCRCs,
                    repairDataURL: attributes["hasparity"].flatMap { URL(string: $0) },
                    syndromeCount: syndromeCount, column0Syndromes: column0))
        }
    }
}

public enum CTDBError: Error, Equatable {
    case malformedResponse
}
