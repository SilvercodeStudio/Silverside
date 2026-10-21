import ArgumentParser
import CDRipDarwin
import CDRipKit
import Foundation

struct Metadata: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Look up a disc in MusicBrainz, and show or keep its release and cover art.")

    @OptionGroup var deviceOptions: DeviceOptions

    @Option(
        name: .shortAndLong,
        help: "A rip's folder. Its disc.json gives the TOC, and gets the release; the cover goes in the folder.")
    var input: String?

    @Option(
        help: "The MusicBrainz ID of the release to use. CDRip keeps the choice for the other discs of the release.")
    var release: String?

    @Option(help: "An image file (JPEG or PNG) to use as the cover, in place of the Cover Art Archive's.")
    var cover: String?

    func run() async throws {
        let folder = input.map { URL(filePath: $0, directoryHint: .isDirectory) }
        let toc: TOC
        var mcn: String?
        if let folder {
            let data = try Data(contentsOf: folder.appending(path: "disc.json"))
            toc = try TOC(ctdbTOCString: JSONDecoder().decode(SavedTOC.self, from: data).toc)
            mcn = (try? JSONDecoder().decode(SavedMCN.self, from: data))?.mcn
        } else {
            let drive = try IOKitDrive(bsdName: deviceOptions.bsdName())
            toc = try drive.readTOC()
            mcn = try? SubchannelCodes.mcn(in: toc, drive: drive)
        }
        print("MusicBrainz disc ID: \(toc.musicBrainzDiscID)" + (mcn.map { ", MCN \($0)" } ?? ""))

        let choice = try await ReleaseChoice.find(toc: toc, mcn: mcn, releaseID: release)
        guard let chosen = choice.chosen else {
            print("MusicBrainz has no release with this disc.")
            return
        }
        if !choice.isExact {
            print("MusicBrainz does not know this disc ID. These releases have nearly the same TOC:")
        }
        for (index, candidate) in choice.ranked.enumerated() {
            let mark = candidate.id == chosen.id ? "*" : " "
            print("\(mark) \(index + 1). " + ReleaseChoice.describe(candidate, discID: toc.musicBrainzDiscID))
        }
        if !choice.ranked.contains(where: { $0.id == chosen.id }) {
            print("* " + ReleaseChoice.describe(chosen, discID: toc.musicBrainzDiscID) + " (from --release)")
        }
        print()
        ReleaseChoice.printTracks(of: chosen, discID: toc.musicBrainzDiscID)

        guard let folder else { return }
        try ReleaseChoice.save(chosen, inDiscJSONOf: folder)
        print()
        print("Saved the release in \(folder.appending(path: "disc.json").path).")
        if let cover {
            let image = CoverImage(data: try Data(contentsOf: URL(filePath: cover)))
            print("Cover: \(try image.write(to: folder).path)")
        } else {
            try await ReleaseChoice.saveFrontCover(of: chosen, in: folder)
        }
    }
}

/// The MCN from a rip's disc.json.
private struct SavedMCN: Decodable {
    var mcn: String?
}

/// Finding, showing, and keeping the release for a disc, for `metadata` and `rip`.
enum ReleaseChoice {
    /// The releases for a disc, the most likely first, and the one to use: the release with
    /// `releaseID` if given (it is then remembered for the other discs of the release), else the first.
    static func find(
        toc: TOC, mcn: String?, releaseID: String?, client: MusicBrainzClient = MusicBrainzClient()
    ) async throws -> (ranked: [MusicBrainzRelease], chosen: MusicBrainzRelease?, isExact: Bool) {
        let lookup = try await client.lookup(toc)
        let discID = toc.musicBrainzDiscID
        let store = ReleaseChoiceStore()
        let ranked = ReleaseRanking.ranked(
            lookup.releases, discID: discID, mcn: mcn, chosen: store.choices(forDiscID: discID))
        guard let releaseID else { return (ranked, ranked.first, lookup.isExact) }
        var chosen = ranked.first { $0.id == releaseID }
        if chosen == nil { chosen = try await client.release(id: releaseID) }
        guard let chosen else { throw CommandError("MusicBrainz has no release \(releaseID).") }
        try store.remember(chosen)
        return (ranked, chosen, lookup.isExact)
    }

    /// One line for a release: "Grateful Dead - Cornell 5/8/77 (2017-05-05, US; disc 2 of 3; ...)".
    static func describe(_ release: MusicBrainzRelease, discID: String) -> String {
        var details = [[release.date, release.country].compactMap { $0 }.joined(separator: ", ")]
        if let medium = release.medium(withDiscID: discID) {
            details.append(release.media.count > 1 ? "disc \(medium.position) of \(release.media.count)" : "1 disc")
        } else {
            details.append("\(release.media.count) discs, none with this disc ID")
        }
        if let barcode = release.barcode, !barcode.isEmpty { details.append("barcode \(barcode)") }
        let labels = release.labels.compactMap { label in
            [label.name, label.catalogNumber].compactMap { $0 }.joined(separator: " ")
        }.filter { !$0.isEmpty }
        if !labels.isEmpty { details.append(labels.joined(separator: ", ")) }
        if let status = release.status, status != "Official" { details.append(status.lowercased()) }
        if let disambiguation = release.disambiguation { details.append(disambiguation) }
        return "\(release.artist) - \(release.title) (\(details.filter { !$0.isEmpty }.joined(separator: "; ")))"
            + "  \(release.id)"
    }

    static func printTracks(of release: MusicBrainzRelease, discID: String) {
        guard let medium = release.medium(withDiscID: discID) ?? release.media.first else { return }
        let title = medium.title.map { ": \($0)" } ?? ""
        print("Disc \(medium.position) of \(release.media.count)\(title)")
        for track in medium.tracks {
            let length = track.length.map { String(format: "%2d:%02d", $0 / 60_000, $0 / 1000 % 60) } ?? "     "
            let artist = track.artist == release.artist ? "" : "\(track.artist) - "
            print(String(format: "  %2d  %@  ", track.position, length) + artist + track.title)
        }
    }

    /// Sets "release" in a folder's disc.json, and keeps every other key.
    static func save(_ release: MusicBrainzRelease, inDiscJSONOf folder: URL) throws {
        let url = folder.appending(path: "disc.json")
        var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        object["release"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(release))
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// Saves the Cover Art Archive's front cover in `folder`, if it has one.
    static func saveFrontCover(of release: MusicBrainzRelease, in folder: URL) async throws {
        guard release.hasFrontCover else {
            print("Cover: the Cover Art Archive has none for this release.")
            return
        }
        guard let image = try await CoverArtClient().frontCover(releaseID: release.id) else {
            print("Cover: not found in the Cover Art Archive.")
            return
        }
        print("Cover: \(try image.write(to: folder).path) (\(image.data.count / 1024) KB)")
    }
}
