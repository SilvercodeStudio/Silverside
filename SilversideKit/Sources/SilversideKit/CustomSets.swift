import Foundation

/// A set of discs that MusicBrainz does not know, made by the user: a box of four CDs, each
/// with only CD-Text, becomes one album of four discs, as a MusicBrainz release of several
/// discs does. Its release (`release`) is one Silverside made, so it gets no MusicBrainz IDs
/// and is never offered to MusicBrainz; unlike a single disc's, its album names and cover are
/// kept by its ID (`MusicBrainzRelease.sharesAlbumEdits`), so every disc of the set gets them.
public struct CustomSet: Codable, Equatable, Identifiable, Sendable {
    /// One disc of the set that was put in it: its disc ID, and its tracks as Silverside named
    /// them (from CD-Text, or "Track N"). The user's names for them stay with each rip.
    public struct Disc: Codable, Equatable, Sendable {
        public var position: Int
        public var discID: String
        public var tracks: [MusicBrainzRelease.Track]

        public init(position: Int, discID: String, tracks: [MusicBrainzRelease.Track]) {
            self.position = position
            self.discID = discID
            self.tracks = tracks
        }
    }

    /// `silverside:set:` and a UUID.
    public var id: String
    public var title: String
    public var artist: String
    public var discCount: Int
    public var discs: [Disc]

    public static let idPrefix = MusicBrainzRelease.manualIDPrefix + "set:"

    public init(title: String, artist: String, discCount: Int, discs: [Disc] = [], id: String? = nil) {
        self.id = id ?? Self.idPrefix + UUID().uuidString.lowercased()
        self.title = title
        self.artist = artist
        self.discCount = discCount
        self.discs = discs
    }

    /// The disc at `position`, if one was put there.
    public func disc(at position: Int) -> Disc? { discs.first { $0.position == position } }

    /// The disc with this TOC, if the set has it.
    public func disc(with toc: TOC) -> Disc? { discs.first { $0.discID == toc.musicBrainzDiscID } }

    /// The positions that no disc has yet.
    public var freePositions: [Int] { (1...max(discCount, 1)).filter { disc(at: $0) == nil } }

    /// Puts the disc with `toc` at `position`, named as `release` names it (a single disc's
    /// manual release); it leaves any other position it had, and a disc that had `position` goes.
    public mutating func put(_ toc: TOC, at position: Int, namedAs release: MusicBrainzRelease) {
        let tracks = release.medium(for: toc)?.tracks ?? release.media.first?.tracks ?? []
        discs.removeAll { $0.discID == toc.musicBrainzDiscID || $0.position == position }
        discs.append(Disc(position: position, discID: toc.musicBrainzDiscID, tracks: tracks))
        discs.sort { $0.position < $1.position }
        discCount = max(discCount, position)
    }

    /// The set as a release of `discCount` CDs. A disc not put in the set yet is a CD with no
    /// tracks and no disc ID, so that the set's page counts it as still to do.
    public var release: MusicBrainzRelease {
        let credit = [MusicBrainzRelease.Credit(name: artist)]
        return MusicBrainzRelease(
            id: id, title: title, artistCredit: credit, date: nil, country: nil, status: nil, barcode: nil,
            disambiguation: nil, labels: [], releaseGroup: nil,
            media: (1...max(discCount, 1)).map { position in
                let disc = disc(at: position)
                return MusicBrainzRelease.Medium(
                    position: position, format: "CD", title: nil, discIDs: disc.map { [$0.discID] } ?? [],
                    tracks: disc?.tracks ?? [])
            }, hasFrontCover: false)
    }
}

/// The custom sets, in a JSON file next to the drive profiles. Rips in several drives can
/// save at once, so a save locks the file.
public struct CustomSetStore: Sendable {
    public let url: URL

    public init(url: URL = DriveProfileStore.defaultDirectory.appending(path: "CustomSets.json")) {
        self.url = url
    }

    /// Every set, the newest first.
    public func sets() -> [CustomSet] { load().reversed() }

    public func set(id: String) -> CustomSet? { load().first { $0.id == id } }

    /// The set that has the disc with this TOC, if one does.
    public func set(containing toc: TOC) -> CustomSet? { load().first { $0.disc(with: toc) != nil } }

    /// Saves the set, in place of one with its ID. A disc of it leaves any other set it was in.
    public func save(_ set: CustomSet) throws {
        try change { all in
            let discIDs = Set(set.discs.map(\.discID))
            for index in all.indices where all[index].id != set.id {
                all[index].discs.removeAll { discIDs.contains($0.discID) }
            }
            if let index = all.firstIndex(where: { $0.id == set.id }) {
                all[index] = set
            } else {
                all.append(set)
            }
        }
    }

    /// Takes the disc with this TOC out of its set. The set stays, for its other discs.
    public func remove(_ toc: TOC) throws {
        try change { all in
            for index in all.indices { all[index].discs.removeAll { $0.discID == toc.musicBrainzDiscID } }
        }
    }

    private func change(_ body: (inout [CustomSet]) -> Void) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = open(url.path + ".lock", O_RDWR | O_CREAT, 0o644)
        guard lock >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { close(lock) }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN) }
        var all = load()
        body(&all)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: url, options: .atomic)
    }

    private func load() -> [CustomSet] {
        (try? JSONDecoder().decode([CustomSet].self, from: Data(contentsOf: url))) ?? []
    }
}

extension MusicBrainzRelease {
    /// True for a custom set (`CustomSet`).
    public var isCustomSet: Bool { id.hasPrefix(CustomSet.idPrefix) }

    /// True if the album's names and cover are kept by the release's ID for its other discs and
    /// rips: a MusicBrainz release, or a custom set. A single disc that Silverside named keeps them
    /// with its rip only.
    public var sharesAlbumEdits: Bool { !isManual || isCustomSet }
}

/// What a disc's CD-Text says about the disc and its tracks, beyond the names themselves.
public enum CDTextHints {
    /// The disc's number in a set, from an album title such as "Seven Classic LPs [Disc 2]",
    /// "Live (CD 2)", "Anthology - Disc 1 of 3", or "Hits Disc2": the title without it, the
    /// number, and the number of discs if the title says.
    public static func disc(inAlbumTitle title: String) -> (title: String, position: Int, count: Int?)? {
        let pattern =
            /^(?<title>.*?\S)(?:[\s\-–—:,]+[\[\(]?|[\[\(])\s*(?:disc|disk|cd)\s*(?<number>\d{1,2})(?:\s*(?:of|\/)\s*(?<count>\d{1,2}))?\s*[\]\)]?\s*$/
            .ignoresCase()
        guard let match = title.wholeMatch(of: pattern), let position = Int(match.output.number), position > 0
        else { return nil }
        let count = match.output.count.flatMap { Int($0) }
        return (String(match.output.title), position, count.flatMap { $0 >= position ? $0 : nil })
    }

    /// The titles without the track numbers that some discs put in front of each title, as
    /// "01 St. Louis Blues" or "1. Intro": only when every titled track starts with its own
    /// number, so that a song called "7 Seconds" keeps its name on a disc whose others do not.
    /// `titles` are by track number; 0, the album's, stays as it is.
    public static func withoutTrackNumbers(_ titles: [Int: String]) -> [Int: String] {
        let pattern = /^0*(?<number>\d{1,2})(?:\s*[.\-–—:)]\s*|\s+)(?<title>\S.*)$/
        var stripped = [Int: String]()
        for (number, title) in titles where number > 0 && !title.isEmpty {
            guard let match = title.wholeMatch(of: pattern), Int(match.output.number) == number else { return titles }
            stripped[number] = String(match.output.title)
        }
        guard stripped.count >= 2 else { return titles }
        return titles.merging(stripped) { _, new in new }
    }
}

extension CDText {
    /// The tracks' titles, by track number, without numbers in front of them
    /// (`CDTextHints.withoutTrackNumbers`), and the album's title at 0 as it is.
    public var trackTitles: [Int: String] { CDTextHints.withoutTrackNumbers(titles) }
}
