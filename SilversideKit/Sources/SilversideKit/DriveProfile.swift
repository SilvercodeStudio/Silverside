import Foundation

/// What Silverside knows about one drive model and firmware: its read offset, and
/// the offsets that matched AccurateRip on past rips.
public struct DriveProfile: Codable, Equatable, Sendable {
    public enum OffsetSource: String, Codable, Sendable {
        /// The user set it.
        case manual
        /// Rips of two or more discs agree on it.
        case confirmed
        /// From AccurateRip's drive offset list.
        case accurateRipList
    }

    /// The offsets that matched AccurateRip on one disc. A disc can match at
    /// several offsets, one for each pressing in the database.
    public struct Observation: Codable, Equatable, Sendable {
        /// The AccurateRip disc ID, such as "dBAR-009-0013f5c6-00949b73-700f6509".
        public var disc: String
        public var offsets: [Int]
        public var date: Date
        /// The disc's name, for people: "Grateful Dead - Reckoning". Nil in older observations.
        public var title: String?
    }

    public var vendor: String
    public var product: String
    public var revision: String
    public var manualOffset: Int?
    public var listedOffset: Int?
    public var observations: [Observation] = []
    /// The drive's cache, in sectors, as `CacheProbe` measured it.
    public var cacheSectors: Int?

    /// Sectors to read far away so that the cache holds none of a track: twice the
    /// measured cache, for a margin, or 4,000 (more than drives were seen to cache).
    public var cacheFlushSectors: Int { cacheSectors.map { max(2 * $0, 256) } ?? 4000 }

    public init(vendor: String, product: String, revision: String) {
        self.vendor = vendor
        self.product = product
        self.revision = revision
    }

    /// Writes every key, with `null` for an empty one, so that a save can clear a value
    /// in the file (see `DriveProfileStore.save`).
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vendor, forKey: .vendor)
        try container.encode(product, forKey: .product)
        try container.encode(revision, forKey: .revision)
        try container.encode(manualOffset, forKey: .manualOffset)
        try container.encode(listedOffset, forKey: .listedOffset)
        try container.encode(observations, forKey: .observations)
        try container.encode(cacheSectors, forKey: .cacheSectors)
    }

    /// The key for this drive in a `DriveProfileStore`.
    public var key: String { "\(vendor) \(product) \(revision)" }

    /// The offset that the most discs share, if at least two do and no other
    /// offset is shared by as many. A disc whose pressing is not in AccurateRip
    /// can match only other pressings, so not every disc has the drive's offset.
    public var confirmedOffset: Int? {
        var counts = [Int: Int]()
        for observation in observations {
            for offset in Set(observation.offsets) { counts[offset, default: 0] += 1 }
        }
        let ranked = counts.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= 2 else { return nil }
        if ranked.count > 1 && ranked[1].value == best.value { return nil }
        return best.key
    }

    /// The offset to rip with: a manual offset, else a confirmed one, else the list's.
    public var offset: (value: Int, source: OffsetSource)? {
        if let manualOffset { return (manualOffset, .manual) }
        if let confirmedOffset { return (confirmedOffset, .confirmed) }
        if let listedOffset { return (listedOffset, .accurateRipList) }
        return nil
    }

    /// Records the offsets that matched on a disc. A new rip of the same disc replaces the old one.
    public mutating func record(disc: String, offsets: [Int], date: Date = Date(), title: String? = nil) {
        observations.removeAll { $0.disc == disc }
        observations.append(Observation(disc: disc, offsets: offsets.sorted(), date: date, title: title))
    }
}

/// Drive profiles, kept in a JSON file. Several processes can use the file at
/// once, for example rips in different drives, so a save changes only its own profile.
public struct DriveProfileStore: Sendable {
    public let url: URL
    public private(set) var profiles: [String: DriveProfile]

    /// ~/Library/Application Support/Silverside, where the app and the CLI keep their data.
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Silverside", directoryHint: .isDirectory)
    }

    /// Loads the store, or starts an empty one if the file does not exist.
    public init(url: URL = defaultDirectory.appending(path: "DriveProfiles.json")) throws {
        self.url = url
        profiles = try Self.load(url)
    }

    private static func load(_ url: URL) throws -> [String: DriveProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder.profiles.decode([String: DriveProfile].self, from: Data(contentsOf: url))
    }

    public func profile(vendor: String, product: String, revision: String) -> DriveProfile {
        let new = DriveProfile(vendor: vendor, product: product, revision: revision)
        return profiles[new.key] ?? new
    }

    /// Saves one profile. Reads the file again under a lock first, so changes
    /// that other processes saved to other profiles are kept. Keys in the file that
    /// this version of Silverside does not know (from a newer version) are kept too.
    public mutating func save(_ profile: DriveProfile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = open(url.path + ".lock", O_RDWR | O_CREAT, 0o644)
        guard lock >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { close(lock) }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN) }

        var file = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        let saved =
            try JSONSerialization.jsonObject(with: JSONEncoder.profiles.encode(profile)) as? [String: Any] ?? [:]
        file[profile.key] = JSONMerge.overlay(saved, on: file[profile.key] as? [String: Any] ?? [:])
        let data = try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        profiles = try JSONDecoder.profiles.decode([String: DriveProfile].self, from: data)
    }
}

extension JSONEncoder {
    fileprivate static var profiles: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var profiles: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
