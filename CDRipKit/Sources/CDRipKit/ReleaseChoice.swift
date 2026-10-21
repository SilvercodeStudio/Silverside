import Foundation

/// Puts the releases that hold a disc in order, the most likely first.
///
/// One disc ID can belong to several releases: other editions, or a box set that holds
/// a whole release (*Madison Square Garden 3/9/81* and the 17-disc *In and Out of the
/// Garden*). So the order is, by each key in turn:
///
/// 1. a release that the user chose before for any disc of the set
/// 2. a barcode that matches the disc's MCN
/// 3. a medium with the disc ID (an exact match, not a fuzzy one)
/// 4. an official release
/// 5. fewer media, so a release comes before a box set that holds it
/// 6. MusicBrainz's own order
public enum ReleaseRanking {
    public static func ranked(
        _ releases: [MusicBrainzRelease], discID: String, mcn: String? = nil, chosen: Set<String> = []
    ) -> [MusicBrainzRelease] {
        func keys(_ release: MusicBrainzRelease) -> [Int] {
            [
                chosen.contains(release.id) ? 0 : 1,
                mcn.map { matches(barcode: release.barcode, mcn: $0) } == true ? 0 : 1,
                release.medium(withDiscID: discID) != nil ? 0 : 1,
                release.status == "Official" ? 0 : 1,
                release.media.count,
            ]
        }
        return releases.enumerated()
            .map { (keys: keys($0.element) + [$0.offset], release: $0.element) }
            .sorted { $0.keys.lexicographicallyPrecedes($1.keys) }
            .map(\.release)
    }

    /// True if a barcode is the MCN. An MCN has 13 digits (EAN-13); a 12-digit UPC is the
    /// same number with a leading zero.
    public static func matches(barcode: String?, mcn: String) -> Bool {
        let digits = (barcode ?? "").filter(\.isNumber)
        guard !digits.isEmpty else { return false }
        let ean = digits.count == 12 ? "0" + digits : digits
        return ean == mcn.filter(\.isNumber)
    }
}

/// The releases that the user chose, by disc ID, kept in a JSON file. Choosing a release
/// for one disc chooses it for every disc of the release, so the other discs of a set
/// get the same release. Rips in several drives can save at once, so a save locks the
/// file and reads it again first.
public struct ReleaseChoiceStore: Sendable {
    public let url: URL

    public init(url: URL = DriveProfileStore.defaultDirectory.appending(path: "ReleaseChoices.json")) {
        self.url = url
    }

    /// The release IDs chosen for a disc ID.
    public func choices(forDiscID discID: String) -> Set<String> {
        Set(load()[discID] ?? [])
    }

    /// Keeps `release` as the choice for each disc ID of its media.
    public func remember(_ release: MusicBrainzRelease) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = open(url.path + ".lock", O_RDWR | O_CREAT, 0o644)
        guard lock >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { close(lock) }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN) }

        var choices = load()
        for discID in release.media.flatMap(\.discIDs) {
            // One choice for each disc: a new choice replaces the old.
            choices[discID] = [release.id]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(choices).write(to: url, options: .atomic)
    }

    private func load() -> [String: [String]] {
        (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))) ?? [:]
    }
}
