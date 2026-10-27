import Foundation

/// The releases that MusicBrainz has for a disc, ranked, and the one to use.
public struct ReleaseLookupResult: Sendable {
    /// The releases, the most likely first.
    public var ranked: [MusicBrainzRelease]
    /// The release to use: the one the user chose, or the first.
    public var chosen: MusicBrainzRelease?
    /// True if MusicBrainz knows the disc ID; false for a fuzzy match of the TOC.
    public var isExact: Bool
    /// Why the chosen release's own lookup failed, if it did. `chosen` is then the disc
    /// lookup's release: the names are all there, but not the writers or the genre.
    public var detailsFailure: String?

    /// The number of releases other than the chosen one.
    public var otherCount: Int {
        ranked.count - (ranked.contains { $0.id == chosen?.id } ? 1 : 0)
    }
}

public enum ReleaseLookupError: Error, Equatable, CustomStringConvertible {
    case noSuchRelease(String)

    public var description: String {
        switch self {
        case .noSuchRelease(let id): "MusicBrainz has no release \(id)."
        }
    }
}

/// Finds the release for a disc: MusicBrainz's releases, ranked (`ReleaseRanking`), and the
/// user's choice when it matters, remembered for the other discs of the release.
public enum ReleaseLookup {
    /// The releases for a disc, and the one to use: the release with `releaseID` if given,
    /// else the first, unless the ranking cannot settle it and `choose` picks another. A
    /// release that the user chose (by ID or with `choose`) is remembered for the other
    /// discs of the release. With `details`, the chosen release is looked up by its ID too,
    /// for what a disc lookup cannot give: the composers of each track. If that lookup fails
    /// (MusicBrainz is busy), the disc lookup's release is used without them, rather than none.
    /// `useCache: false` asks MusicBrainz again, not the cache: for Look Up Metadata, after an edit there.
    public static func find(
        toc: TOC, mcn: String?, releaseID: String? = nil, details: Bool = false,
        choose: (([MusicBrainzRelease]) -> MusicBrainzRelease?)? = nil,
        client: MusicBrainzClient = MusicBrainzClient(), store: ReleaseChoiceStore = ReleaseChoiceStore(),
        useCache: Bool = true
    ) async throws -> ReleaseLookupResult {
        let lookup = try await client.lookup(toc, useCache: useCache)
        let discID = toc.musicBrainzDiscID
        let remembered = store.choices(forDiscID: discID)
        let others = store.allChoices()
        let ranked = ReleaseRanking.ranked(
            lookup.releases, discID: discID, mcn: mcn, chosen: remembered, chosenForOtherDiscs: others)
        guard let releaseID else {
            var chosen = ranked.first
            if let choose,
                ReleaseRanking.isAmbiguous(ranked, mcn: mcn, chosen: remembered, chosenForOtherDiscs: others)
            {
                chosen = choose(ranked)
                if let chosen { try store.remember(chosen) }
            }
            var failure: String?
            if details, let summary = chosen {
                (chosen, failure) = try await detailed(summary, client: client, useCache: useCache)
            }
            return ReleaseLookupResult(
                ranked: ranked, chosen: chosen, isExact: lookup.isExact, detailsFailure: failure)
        }
        var chosen = ranked.first { $0.id == releaseID }
        var failure: String?
        if let summary = chosen, details {
            (chosen, failure) = try await detailed(summary, client: client, useCache: useCache)
        } else if chosen == nil {
            chosen = try await client.release(id: releaseID, useCache: useCache)
        }
        guard let chosen else { throw ReleaseLookupError.noSuchRelease(releaseID) }
        try store.remember(chosen)
        return ReleaseLookupResult(ranked: ranked, chosen: chosen, isExact: lookup.isExact, detailsFailure: failure)
    }

    /// The release looked up by its ID, or the summary and why that lookup failed.
    private static func detailed(
        _ summary: MusicBrainzRelease, client: MusicBrainzClient, useCache: Bool
    ) async throws -> (MusicBrainzRelease, String?) {
        do {
            return (try await client.release(id: summary.id, useCache: useCache) ?? summary, nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (summary, "\(error)")
        }
    }
}

extension MusicBrainzRelease {
    /// One line for the release and the disc with `toc`: "Grateful Dead - Cornell 5/8/77
    /// (2017-05-05, US; disc 2 of 3; barcode ...; Rhino R2 557480)  <ID>".
    public func summary(for toc: TOC) -> String {
        var details = [[date, country].compactMap { $0 }.joined(separator: ", ")]
        if let disc = medium(for: toc) {
            let how = medium(withDiscID: toc.musicBrainzDiscID) == nil ? " (by track lengths)" : ""
            details.append((media.count > 1 ? "disc \(disc.position) of \(media.count)" : "1 disc") + how)
        } else {
            details.append("\(media.count) discs; which one is this disc is not clear")
        }
        if let barcode, !barcode.isEmpty { details.append("barcode \(barcode)") }
        let labelText = labels.compactMap { label in
            [label.name, label.catalogNumber].compactMap { $0 }.joined(separator: " ")
        }.filter { !$0.isEmpty }
        if !labelText.isEmpty { details.append(labelText.joined(separator: ", ")) }
        if let status, status != "Official" { details.append(status.lowercased()) }
        if let disambiguation { details.append(disambiguation) }
        return "\(artist) - \(title) (\(details.filter { !$0.isEmpty }.joined(separator: "; ")))  \(id)"
    }

    /// Sets "release" in a folder's disc.json, and keeps every other key.
    public func save(inDiscJSONOf folder: URL) throws {
        let url = folder.appending(path: "disc.json")
        var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        object["release"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}

/// What saving a release's artwork did.
public enum ArtworkResult: Equatable, Sendable {
    /// Nothing was asked for.
    case notWanted
    /// The Cover Art Archive has no images for the release.
    case noneInArchive
    /// The images, as saved.
    case saved([URL])
}

extension CoverArtClient {
    /// Saves the release's artwork in `folder`: the front cover as cover.jpg, and with
    /// `.all`, the other images in Artwork/.
    public func saveArtwork(_ choice: ArtworkChoice, of release: MusicBrainzRelease, in folder: URL) async throws
        -> ArtworkResult
    {
        guard choice != .none else { return .notWanted }
        guard release.hasFrontCover || (release.artworkCount ?? 0) > 0 else { return .noneInArchive }
        let files = try await save(releaseID: release.id, in: folder, all: choice == .all)
        return files.isEmpty ? .noneInArchive : .saved(files)
    }
}
