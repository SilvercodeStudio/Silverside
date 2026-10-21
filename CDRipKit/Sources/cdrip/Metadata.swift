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
            guard let saved = RipPool.savedTOC(in: folder) else {
                throw CommandError("\(folder.appending(path: "disc.json").path) has no TOC.")
            }
            toc = try TOC(ctdbTOCString: saved)
            let data = try? Data(contentsOf: folder.appending(path: "disc.json"))
            mcn = data.flatMap { try? JSONDecoder().decode(SavedMCN.self, from: $0) }?.mcn
        } else {
            let drive = try IOKitDrive(bsdName: deviceOptions.bsdName())
            toc = try drive.readTOC()
            mcn = try? SubchannelCodes.mcn(in: toc, drive: drive)
        }
        print("MusicBrainz disc ID: \(toc.musicBrainzDiscID)" + (mcn.map { ", MCN \($0)" } ?? ""))

        let choice = try await ReleaseLookup.find(toc: toc, mcn: mcn, releaseID: release)
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
            print("\(mark) \(index + 1). " + candidate.summary(for: toc))
        }
        if !choice.ranked.contains(where: { $0.id == chosen.id }) {
            print("* " + chosen.summary(for: toc) + " (from --release)")
        }
        print()
        ReleaseChoice.printTracks(of: chosen, toc: toc)

        guard let folder else { return }
        try chosen.save(inDiscJSONOf: folder)
        print()
        print("Saved the release in \(folder.appending(path: "disc.json").path).")
        if let cover {
            let image = CoverImage(data: try Data(contentsOf: URL(filePath: cover)))
            print("Cover: \(try image.write(to: folder).path)")
        } else {
            ReleaseChoice.printArtwork(
                try await CoverArtClient().saveArtwork(artwork ?? Settings.load().artwork, of: chosen, in: folder))
        }
    }
}

/// The MCN from a rip's disc.json.
private struct SavedMCN: Decodable {
    var mcn: String?
}

/// Asking for a release, and showing one, on the terminal, for `metadata` and `rip`.
enum ReleaseChoice {
    /// Asks the user to pick a release, on the terminal. The first is the default.
    static func askForRelease(_ ranked: [MusicBrainzRelease], toc: TOC) -> MusicBrainzRelease? {
        print("Several MusicBrainz releases have this disc:")
        for (index, release) in ranked.enumerated() {
            print("  \(index + 1). " + release.summary(for: toc))
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

    static func printArtwork(_ result: ArtworkResult) {
        switch result {
        case .notWanted:
            break
        case .noneInArchive:
            print("Cover: the Cover Art Archive has none for this release.")
        case .saved(let files):
            for file in files {
                let size = ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) / 1024
                print("Cover: \(file.path) (\(size) KB)")
            }
        }
    }
}
