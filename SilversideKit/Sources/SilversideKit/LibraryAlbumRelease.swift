import Foundation

/// How a release's media fit an album folder's files, in order: a run of whole media (one disc,
/// or every disc of a set) with as many tracks as there are files, each length that both know
/// agreeing (`MusicBrainzRelease.lengthsAgree`).
public struct AlbumFit: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Each length that MusicBrainz has agrees with its file's.
        case lengths
        /// As many tracks, but no length to compare.
        case trackCountOnly
    }

    /// The positions of the media that the files are, in order.
    public var media: [Int]
    public var kind: Kind
    /// The release's tracks, one for each file.
    public var tracks: [MusicBrainzRelease.Track]
    /// The largest difference between a track's length and its file's, in milliseconds; nil
    /// if there was none to compare.
    public var largestDifference: Int?
    /// The sum of the differences, to rank fits.
    public var totalDifference: Int
}

extension MusicBrainzRelease {
    /// The best run of whole media for files of these lengths (nil where a file's is not
    /// known), or nil if none fits.
    public func fit(lengths: [Int?]) -> AlbumFit? {
        var best: AlbumFit?
        for first in media.indices {
            var tracks = [Track]()
            for last in first..<media.count {
                tracks += media[last].tracks
                if tracks.count > lengths.count { break }
                guard tracks.count == lengths.count else { continue }
                let pairs = zip(tracks, lengths).compactMap { track, length in
                    track.length.flatMap { listed in length.map { (listed, $0) } }
                }
                guard pairs.allSatisfy({ Self.lengthsAgree($0.0, $0.1) }) else { continue }
                let differences = pairs.map { abs($0.0 - $0.1) }
                let fit = AlbumFit(
                    media: media[first...last].map(\.position), kind: pairs.isEmpty ? .trackCountOnly : .lengths,
                    tracks: tracks, largestDifference: differences.max(), totalDifference: differences.reduce(0, +))
                if best.map({ Self.ranks(fit, before: $0) }) ?? true { best = fit }
            }
        }
        return best
    }

    /// True if `fit` is better: lengths before a count alone, then the smaller differences.
    static func ranks(_ fit: AlbumFit, before other: AlbumFit) -> Bool {
        if (fit.kind == .lengths) != (other.kind == .lengths) { return fit.kind == .lengths }
        return fit.totalDifference < other.totalDifference
    }

    /// True if a run of whole media with these track counts (a search's) can hold `files`
    /// files, before the release is looked up. A search counts an Enhanced CD's data track,
    /// which the release's lookup leaves out (`MusicBrainzClient`), so each disc may have one
    /// track more.
    static func canFit(trackCounts counts: [Int], files: Int) -> Bool {
        for first in counts.indices {
            var total = 0
            for last in first..<counts.count {
                total += counts[last]
                if (files...(files + last - first + 1)).contains(total) { return true }
                if total > files + counts.count { break }
            }
        }
        return false
    }
}

/// A release that may be the album folder's, and how it fits the files.
public struct AlbumReleaseCandidate: Sendable {
    public enum Source: Equatable, Sendable {
        /// The user named it (`--release`).
        case given
        /// An earlier run's choice, kept in the folder.
        case kept
        /// The files' MusicBrainz Album Id tag.
        case tags
        /// A MusicBrainz search, with its score.
        case search(score: Int)
    }

    public var release: MusicBrainzRelease
    public var fit: AlbumFit?
    public var source: Source
}

/// Finds the release that an album folder holds: the one the user names, else the one kept in
/// the folder, else the one in the files' tags, else MusicBrainz's search, by the files' album
/// and artist (or the folder's names), with the track counts and lengths deciding. A search
/// decides nothing by itself: many releases of an album have the same tracks, and the cover
/// is what tells them apart, so its candidates go to the user.
public struct AlbumReleaseFinder: Sendable {
    public struct Result: Sendable {
        /// The release to use, when it is certain: named, kept, or tagged.
        public var chosen: AlbumReleaseCandidate?
        /// What the search found that fits, the best first; empty when a release was certain.
        public var candidates: [AlbumReleaseCandidate]
        /// The words searched for, if there was a search.
        public var searched: String?
        /// The search's releases that may fit but could not be looked up (MusicBrainz busy, or
        /// another failure after the retries), by ID: left out of `candidates`.
        public var unavailable: [String] = []
    }

    public var client: MusicBrainzClient
    /// The most releases a search looks up, for their track lengths: one small request each.
    public var lookups = 8
    /// How often a full lookup of one release is asked while MusicBrainz answers 503: the
    /// waits double from 2 s, about a minute in all. A big release with every relationship
    /// (*1967–1970*'s 28 tracks, about 800 KB) was refused past the usual 4 tries.
    public var fullAttempts = 6

    public init(client: MusicBrainzClient = MusicBrainzClient()) {
        self.client = client
    }

    /// `releaseID` may be a MusicBrainz release ID or its page's URL. `search` replaces the words
    /// that the files' tags give.
    public func find(for album: LibraryAlbum, releaseID: String? = nil, search: String? = nil) async throws -> Result {
        let lengths = album.lengths
        func candidate(_ id: String, _ source: AlbumReleaseCandidate.Source) async throws -> AlbumReleaseCandidate {
            guard let release = try await client.release(id: id, attempts: fullAttempts) else {
                throw AlbumReleaseError.noSuchRelease(id)
            }
            return AlbumReleaseCandidate(release: release, fit: release.fit(lengths: lengths), source: source)
        }
        if let releaseID {
            guard let id = Self.releaseID(in: releaseID) else { throw AlbumReleaseError.notAReleaseID(releaseID) }
            return Result(chosen: try await candidate(id, .given), candidates: [])
        }
        if search == nil {
            if let kept = album.choice?.releaseID {
                return Result(chosen: try await candidate(kept, .kept), candidates: [])
            }
            if let tagged = album.taggedReleaseID, Self.releaseID(in: tagged) != nil {
                let found = try await candidate(tagged, .tags)
                if found.fit != nil { return Result(chosen: found, candidates: []) }
            }
        }
        // The barcode in the tags first, which names one release, or a few.
        var found = [MusicBrainzSearchResult]()
        var searched = [String]()
        if search == nil, let barcode = album.commonTag("BARCODE"), MusicBrainzClient.barcodeQuery(for: barcode) != nil
        {
            found += try await client.searchReleases(barcode, limit: 10)
            searched.append(barcode)
        }
        var candidates = [AlbumReleaseCandidate]()
        var unavailable = [String]()
        var lookedUp = Set<String>()
        // Each query until one finds releases that fit: the narrower one first.
        for query in search.map({ [$0] }) ?? Self.searchQueries(for: album) {
            let more = try await client.searchReleases(query, limit: 25)
            found += more.filter { result in !found.contains { $0.id == result.id } }
            searched.append(query)
            let fitting = found.filter {
                !lookedUp.contains($0.id)
                    && MusicBrainzRelease.canFit(trackCounts: $0.media.map(\.trackCount), files: album.files.count)
            }
            for result in fitting.prefix(lookups) {
                lookedUp.insert(result.id)
                // The tracklist only: the release chosen is looked up in full (`complete`). One
                // that fails is left out, so a busy MusicBrainz does not stop the others.
                let release: MusicBrainzRelease
                do {
                    guard let found = try await client.tracklist(id: result.id) else { continue }
                    release = found
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    unavailable.append(result.id)
                    continue
                }
                guard let fit = release.fit(lengths: lengths) else { continue }
                candidates.append(
                    AlbumReleaseCandidate(release: release, fit: fit, source: .search(score: result.score)))
            }
            if !candidates.isEmpty { break }
        }
        candidates.sort { a, b in
            guard let left = a.fit, let right = b.fit else { return a.fit != nil }
            if MusicBrainzRelease.ranks(left, before: right) { return true }
            if MusicBrainzRelease.ranks(right, before: left) { return false }
            return a.score > b.score
        }
        return Result(
            candidates: candidates, searched: searched.isEmpty ? nil : searched.joined(separator: ", then "),
            unavailable: unavailable)
    }

    /// The candidate with its release in full (credits, composers, genres, disc IDs), for
    /// the tags: a search's candidates have only their tracklists. Others are full already.
    public func complete(_ candidate: AlbumReleaseCandidate) async throws -> AlbumReleaseCandidate {
        guard case .search = candidate.source else { return candidate }
        let release: MusicBrainzRelease?
        do {
            release = try await client.release(id: candidate.release.id, attempts: fullAttempts)
        } catch OnlineLookupError.httpStatus(let status, _) where status == 503 || status == 429 {
            throw AlbumReleaseError.busy(candidate.release.id)
        }
        guard let release else { throw AlbumReleaseError.noSuchRelease(candidate.release.id) }
        var full = candidate
        full.release = release
        return full
    }

    /// The queries to search with, the narrowest first: the album and its artist, from the tags,
    /// else the folder's name and its parent's (Artist/Album). Words in brackets ("Abbey Road
    /// (2009 Stereo Remaster)") are no part of a title on MusicBrainz. In an album tag they are
    /// often a release's disambiguation (`comment:`): the first query asks for one of them there,
    /// the second does without. In a folder's name they are more often a year or a source
    /// ("(1986)", "[24-96 FLAC]"), so they are left out. Last, the title as a phrase with no
    /// artist: the files' artist can differ from the release's (the band in the tags, its
    /// leaders on MusicBrainz), and the words of a long title ranked other releases first.
    /// Empty if there is no album name.
    static func searchQueries(for album: LibraryAlbum) -> [String] {
        let tagged = album.commonTag("ALBUM")
        let name = tagged ?? album.folder.lastPathComponent
        let artist =
            album.commonTag("ALBUMARTIST") ?? album.commonTag("ARTIST")
            ?? album.folder.deletingLastPathComponent().lastPathComponent
        let bracketed = /[(\[]([^)\]]*)[)\]]/
        let extras = name.matches(of: bracketed).map { String($0.output.1) }.joined(separator: " ")
        let title = name.replacing(bracketed, with: " ")
        func words(_ text: String) -> String {
            let special = Set("+-&|!(){}[]^\"~*?:\\/")
            return text.split(separator: " ").map { word in
                String(word.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
            }.joined(separator: " ")
        }
        let titleWords = words(title)
        guard !titleWords.isEmpty else { return [] }
        var query = "release:(\(titleWords))"
        let artistWords = words(artist)
        if !artistWords.isEmpty { query += " AND artist:(\(artistWords))" }
        let extraWords = tagged == nil ? "" : words(extras)
        var queries = extraWords.isEmpty ? [query] : [query + " AND comment:(\(extraWords))", query]
        let phrase = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
        queries.append("release:\"\(phrase)\"")
        return queries
    }

    /// The release ID in `text`: an ID, or a MusicBrainz release page's URL.
    public static func releaseID(in text: String) -> String? {
        let pattern = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/
        return text.firstMatch(of: pattern).map { String($0.output).lowercased() }
    }
}

extension AlbumReleaseCandidate {
    var score: Int {
        if case .search(let score) = source { return score }
        return 100
    }
}

public enum AlbumReleaseError: Error, Equatable, CustomStringConvertible {
    case notAReleaseID(String)
    case noSuchRelease(String)
    /// MusicBrainz kept answering 503 for the chosen release's full lookup.
    case busy(String)

    public var description: String {
        switch self {
        case .notAReleaseID(let text): "\"\(text)\" is not a MusicBrainz release ID or a release's page."
        case .noSuchRelease(let id): "MusicBrainz has no release \(id)."
        case .busy(let id):
            "MusicBrainz is busy and did not give the release's credits and composers, so nothing was written. "
                + "Run the command again later; --release \(id) skips the search and the choice."
        }
    }
}
