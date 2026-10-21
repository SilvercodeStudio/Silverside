import ArgumentParser
import CDRipDarwin
import CDRipKit
import Foundation

struct Metadata: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Look up a disc in MusicBrainz, and show or keep its release and cover art.",
        discussion: """
            Shows the releases that have the disc, the most likely first, and the tracks of the one CDRip would \
            use. With -i, it keeps that release in the rip's disc.json, so the rip can be encoded and tagged, and \
            saves the cover. A choice made with --release is kept for the other discs of the release.

            Examples:
              cdrip metadata -d disk14
              cdrip metadata -i "<rip folder>"
              cdrip metadata -i "<rip folder>" --release aa0d7d7e-1d78-4f78-ba03-7a32c200f660 --artwork all
            """)

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

    @Option(help: "The artwork to save from the Cover Art Archive: front (cover.jpg), all (also Artwork/), or none.")
    var artwork: ArtworkChoice?

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
            print("MusicBrainz does not know this disc ID. These releases have nearly the same TOC.")
            print(
                "To add the disc ID to the right release: \(MusicBrainzRelease.submissionURL(for: toc).absoluteString)")
        }
        for (index, candidate) in choice.ranked.enumerated() {
            let mark = candidate.id == chosen.id ? "*" : " "
            print("\(mark) \(index + 1). " + ReleaseChoice.describe(candidate, toc: toc))
        }
        if !choice.ranked.contains(where: { $0.id == chosen.id }) {
            print("* " + ReleaseChoice.describe(chosen, toc: toc) + " (from --release)")
        }
        print()
        ReleaseChoice.printTracks(of: chosen, toc: toc)

        guard let folder else { return }
        try ReleaseChoice.save(chosen, inDiscJSONOf: folder)
        print()
        print("Saved the release in \(folder.appending(path: "disc.json").path).")
        if let cover {
            let image = CoverImage(data: try Data(contentsOf: URL(filePath: cover)))
            print("Cover: \(try image.write(to: folder).path)")
        } else {
            try await ReleaseChoice.saveArtwork(artwork ?? Settings.load().artwork, of: chosen, in: folder)
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
        toc: TOC, mcn: String?, releaseID: String?, ask: Bool = false, client: MusicBrainzClient = MusicBrainzClient()
    ) async throws -> (ranked: [MusicBrainzRelease], chosen: MusicBrainzRelease?, isExact: Bool) {
        let lookup = try await client.lookup(toc)
        let discID = toc.musicBrainzDiscID
        let store = ReleaseChoiceStore()
        let ranked = ReleaseRanking.ranked(
            lookup.releases, discID: discID, mcn: mcn, chosen: store.choices(forDiscID: discID))
        guard let releaseID else {
            var chosen = ranked.first
            if ask, ReleaseRanking.isAmbiguous(ranked, mcn: mcn, chosen: store.choices(forDiscID: discID)) {
                chosen = askForRelease(ranked, toc: toc)
                if let chosen { try store.remember(chosen) }
            }
            return (ranked, chosen, lookup.isExact)
        }
        var chosen = ranked.first { $0.id == releaseID }
        if chosen == nil { chosen = try await client.release(id: releaseID) }
        guard let chosen else { throw CommandError("MusicBrainz has no release \(releaseID).") }
        try store.remember(chosen)
        return (ranked, chosen, lookup.isExact)
    }

    /// Asks the user to pick a release, on the terminal. The first is the default.
    static func askForRelease(_ ranked: [MusicBrainzRelease], toc: TOC) -> MusicBrainzRelease? {
        print("Several MusicBrainz releases have this disc:")
        for (index, release) in ranked.enumerated() {
            print("  \(index + 1). " + describe(release, toc: toc))
        }
        while true {
            print("Which release? [1] ", terminator: "")
            fflush(stdout)
            guard let line = readLine()?.trimmingCharacters(in: .whitespaces) else { return ranked.first }
            if line.isEmpty { return ranked.first }
            if let number = Int(line), ranked.indices.contains(number - 1) { return ranked[number - 1] }
            print("Give a number from 1 to \(ranked.count).")
        }
    }

    /// One line for a release: "Grateful Dead - Cornell 5/8/77 (2017-05-05, US; disc 2 of 3; ...)".
    static func describe(_ release: MusicBrainzRelease, toc: TOC) -> String {
        var details = [[release.date, release.country].compactMap { $0 }.joined(separator: ", ")]
        if let medium = release.medium(for: toc) {
            let how = release.medium(withDiscID: toc.musicBrainzDiscID) == nil ? " (by track lengths)" : ""
            details.append(
                (release.media.count > 1 ? "disc \(medium.position) of \(release.media.count)" : "1 disc") + how)
        } else {
            details.append("\(release.media.count) discs; which one is this disc is not clear")
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

    static func printTracks(of release: MusicBrainzRelease, toc: TOC) {
        guard let medium = release.medium(for: toc) else {
            print("Which disc of the release this is is not clear: no disc has its track count and lengths.")
            return
        }
        let title = medium.title.map { ": \($0)" } ?? ""
        let seconds = toc.audioTracks.reduce(0) { $0 + toc.sectorRange(of: $1).count } / CDDA.sectorsPerSecond
        print(
            "Disc \(medium.position) of \(release.media.count)\(title), "
                + String(format: "%d:%02d", seconds / 60, seconds % 60))
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

    /// Saves the Cover Art Archive's artwork for the release in `folder`: the front cover as
    /// cover.jpg, and with `.all`, the other images in Artwork/.
    static func saveArtwork(_ artwork: ArtworkChoice, of release: MusicBrainzRelease, in folder: URL) async throws {
        guard artwork != .none else { return }
        guard release.hasFrontCover || (release.artworkCount ?? 0) > 0 else {
            print("Cover: the Cover Art Archive has none for this release.")
            return
        }
        let files = try await CoverArtClient().save(releaseID: release.id, in: folder, all: artwork == .all)
        if files.isEmpty { print("Cover: not found in the Cover Art Archive.") }
        for file in files {
            let size = ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) / 1024
            print("Cover: \(file.path) (\(size) KB)")
        }
    }
}
