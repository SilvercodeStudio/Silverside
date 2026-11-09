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
    /// The disc ID and the TOC found nothing, and the releases came from the disc's barcode
    /// (its MCN), with a disc whose tracks fit this one's.
    public var foundByBarcode = false

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
        var lookup = try await client.lookup(toc, useCache: useCache)
        var foundByBarcode = false
        if lookup.releases.isEmpty, let mcn {
            lookup.releases = try await barcodeMatches(mcn: mcn, toc: toc, client: client, useCache: useCache)
            foundByBarcode = !lookup.releases.isEmpty
        }
        let discID = toc.musicBrainzDiscID
        let remembered = store.choices(forDiscID: discID)
        let others = store.allChoices()
        let ranked = ReleaseRanking.ranked(
            lookup.releases, discID: discID, mcn: mcn, chosen: remembered, chosenForOtherDiscs: others)
        guard let releaseID else {
            // The user said that none of the releases is this disc: they only nearly fit it.
            if store.hasNoRelease(forDiscID: discID) {
                return ReleaseLookupResult(
                    ranked: ranked, chosen: nil, isExact: lookup.isExact, foundByBarcode: foundByBarcode)
            }
            var chosen = ranked.first
            if let choose,
                ReleaseRanking.isAmbiguous(ranked, mcn: mcn, chosen: remembered, chosenForOtherDiscs: others)
            {
                chosen = choose(ranked)
                if let chosen { try store.remember(chosen, forDiscID: discID) }
            }
            var failure: String?
            if details, let summary = chosen {
                (chosen, failure) = try await detailed(summary, client: client, useCache: useCache)
            }
            return ReleaseLookupResult(
                ranked: ranked, chosen: chosen, isExact: lookup.isExact, detailsFailure: failure,
                foundByBarcode: foundByBarcode)
        }
        var chosen = ranked.first { $0.id == releaseID }
        var failure: String?
        if let summary = chosen, details {
            (chosen, failure) = try await detailed(summary, client: client, useCache: useCache)
        } else if chosen == nil {
            chosen = try await client.release(id: releaseID, useCache: useCache)
        }
        guard let chosen else { throw ReleaseLookupError.noSuchRelease(releaseID) }
        try store.remember(chosen, forDiscID: discID)
        return ReleaseLookupResult(
            ranked: ranked, chosen: chosen, isExact: lookup.isExact, detailsFailure: failure,
            foundByBarcode: foundByBarcode)
    }

    /// The releases with the disc's barcode (its MCN) that have a disc whose tracks fit this
    /// one's, by count and by each length (`MusicBrainzRelease.fit(for:)`): for a pressing whose
    /// disc ID MusicBrainz does not have. A reissue can keep the barcode and change the tracks.
    /// One search, and a lookup of each release whose track counts can fit (at most 3): a search
    /// counts a Mixed Mode CD's data track, or a hidden track, which the release's lookup leaves
    /// out. A failure finds none: the barcode is only a second chance.
    static func barcodeMatches(
        mcn: String, toc: TOC, client: MusicBrainzClient, useCache: Bool
    ) async throws -> [MusicBrainzRelease] {
        guard MusicBrainzClient.barcodeQuery(for: mcn) != nil,
            let found = try? await client.searchReleases(mcn, limit: 10, useCache: useCache)
        else { return [] }
        let count = toc.audioTracks.count
        var releases = [MusicBrainzRelease]()
        for result in found.filter({
            !($0.positions(withTrackCount: count) + $0.positions(withTrackCount: count + 1)).isEmpty
        }).prefix(3) {
            try Task.checkCancellation()
            if let release = try? await client.release(id: result.id, useCache: useCache),
                let fit = release.fit(for: toc), fit.kind != .trackCountOnly
            {
                releases.append(release)
            }
        }
        return releases
    }

    /// The release looked up by its ID, or the summary and why that lookup failed.
    /// The release for a disc as an earlier lookup found it, from the cache, with no request:
    /// the remembered choice if there is one, else the best ranked. Nil if the disc was never
    /// found. For `silverside drives`, which names the disc in each drive.
    public static func cachedRelease(
        toc: TOC, client: MusicBrainzClient = MusicBrainzClient(), store: ReleaseChoiceStore = ReleaseChoiceStore()
    ) -> MusicBrainzRelease? {
        guard let lookup = client.cachedLookup(toc), !lookup.releases.isEmpty else { return nil }
        let discID = toc.musicBrainzDiscID
        return ReleaseRanking.ranked(
            lookup.releases, discID: discID, mcn: nil, chosen: store.choices(forDiscID: discID),
            chosenForOtherDiscs: store.allChoices()
        ).first
    }

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
    /// The images, as saved; `fromRelease` is the other release they came from, if they are
    /// not the release's own.
    case saved([URL], fromRelease: String? = nil)
}

extension CoverArtClient {
    /// Saves the release's artwork in `folder`: the front cover as cover.jpg, and with
    /// `.all`, the other images in Artwork/. The images are those of `source` when the user
    /// chose another release's (`ReleaseCoverStore.artworkRelease`). A release with none of
    /// its own takes its release group's: another edition's, as the archive chooses it
    /// (*Live at Stubb's*: Epic EK 96464 has none, the Or Music release has three).
    public func saveArtwork(
        _ choice: ArtworkChoice, of release: MusicBrainzRelease, in folder: URL, from source: String? = nil
    ) async throws -> ArtworkResult {
        guard choice != .none else { return .notWanted }
        if (source != nil && source != release.id) || !(release.hasFrontCover || (release.artworkCount ?? 0) > 0) {
            let found = try await artworkImages(of: release, from: source)
            let files = try await save(found.images, in: folder, all: choice == .all)
            return files.isEmpty ? .noneInArchive : .saved(files, fromRelease: found.fromRelease)
        }
        do {
            let files = try await save(releaseID: release.id, in: folder, all: choice == .all)
            return files.isEmpty ? .noneInArchive : .saved(files)
        } catch let error where !(error is CancellationError) {
            // The archive's list of images can fail (archive.org behind it is busy) when its front
            // cover does not; the app showed that cover as the disc was read, and the web cache
            // keeps it. Nine Inch Nails *Broken* (2026-10-30) got no cover when the list failed.
            guard let front = try? await frontCover(releaseID: release.id) else { throw error }
            return .saved([try front.write(to: folder)])
        }
    }
}
