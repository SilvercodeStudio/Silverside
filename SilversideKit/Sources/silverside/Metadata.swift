import ArgumentParser
import Foundation
import SilversideDarwin
import SilversideKit

struct Metadata: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Look up a disc in MusicBrainz, and show or keep its release and cover art.",
        discussion: """
            Shows the releases that have the disc, the most likely first, and the tracks of the one Silverside would \
            use. With -i, it keeps that release in the rip's disc.json, so the rip can be encoded and tagged, and \
            saves the cover. A choice made with --release is kept for the other discs of the release.

            Examples:
              silverside metadata -d disk14
              silverside metadata -i "<rip folder>"
              silverside metadata -i "<rip folder>" --release aa0d7d7e-1d78-4f78-ba03-7a32c200f660 --artwork all
              silverside metadata -i "<rip folder>" --set "album=Cornell 5/8/77" --set "track3.title=El Paso"
              silverside metadata -i "<rip folder>" --manual --set "albumArtist=Phish" --set "album=Live in Vegas"
            """)

    @OptionGroup var deviceOptions: DeviceOptions

    @Option(
        name: .shortAndLong,
        help: "A rip's folder. Its disc.json gives the TOC, and gets the release; the cover goes in the folder.")
    var input: String?

    @Option(
        help:
            "The MusicBrainz ID of the release to use. Silverside keeps the choice for the other discs of the release.")
    var release: String?

    @Option(
        help:
            "An image file to use as the cover, in place of the Cover Art Archive's. JPEG and PNG are kept as they are; other formats, such as WebP or HEIC, become JPEG."
    )
    var cover: String?

    @Option(help: "The artwork to save from the Cover Art Archive: front (cover.jpg), all (also Artwork/), or none.")
    var artwork: ArtworkChoice?

    @Option(
        name: .customLong("set"),
        help: """
            Change a name: album=..., albumArtist=..., date=..., track3.title=..., or track3.artist=.... Give it more \
            than once. An empty value puts the original back. The album's names are kept for the release, so the \
            other discs of a set get them; a track's names need the rip's folder (-i).
            """)
    var sets: [String] = []

    @Flag(help: "Remove every edit of the disc, and of its release's album names.")
    var clearEdits = false

    @Flag(help: "Write the names and the cover into the album's encoded files again, if the rip was encoded (with -i).")
    var retag = false

    @Flag(
        help: """
            When MusicBrainz has no release for the disc, make one from the disc's CD-Text (or "Unknown Artist" and \
            "Unknown Album"), to fill in with --set. Its files get no MusicBrainz IDs.
            """)
    var manual = false

    func run() async throws {
        let folder = input.map { URL(filePath: $0, directoryHint: .isDirectory) }
        let toc: TOC
        var mcn: String?
        var cdText: CDText?
        if let folder {
            guard let saved = RipPool.savedTOC(in: folder) else {
                throw CommandError("\(folder.appending(path: "disc.json").path) has no TOC.")
            }
            toc = try TOC(ctdbTOCString: saved)
            let data = try? Data(contentsOf: folder.appending(path: "disc.json"))
            mcn = data.flatMap { try? JSONDecoder().decode(SavedMCN.self, from: $0) }?.mcn
            cdText = (try? RipReport.read(from: folder.appending(path: "disc.json")))?.cdText
        } else {
            let drive = try IOKitDrive(bsdName: deviceOptions.bsdName())
            toc = try drive.readTOC()
            mcn = try? SubchannelCodes.mcn(in: toc, drive: drive)
            cdText = (try? drive.readCDText()).flatMap { $0.flatMap(CDText.init(bytes:)) }
        }
        print("MusicBrainz disc ID: \(toc.musicBrainzDiscID)" + (mcn.map { ", MCN \($0)" } ?? ""))

        let choice = try await ReleaseLookup.find(toc: toc, mcn: mcn, releaseID: release, details: true)
        var chosen = choice.chosen
        if chosen == nil, manual { chosen = MusicBrainzRelease.manual(toc: toc, cdText: cdText) }
        guard let chosen else {
            print("MusicBrainz has no release with this disc. --manual makes one to name with --set.")
            return
        }
        if chosen.isManual {
            print(
                "No MusicBrainz release: the names come from " + (cdText == nil ? "nowhere yet" : "the disc's CD-Text")
                    + ".")
        }
        if let failure = choice.detailsFailure {
            print("The release's own lookup failed (\(failure)): no writers or genre. Run this again later for them.")
        }
        if !choice.isExact, !chosen.isManual {
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
        // The edits: the rip's, else the ones kept for the release; then this command's changes.
        let store = ReleaseEditsStore()
        var edits =
            folder.flatMap(MetadataEdits.read(fromDiscJSONOf:))
            ?? (chosen.isManual ? nil : store.edits(forReleaseID: chosen.id)) ?? MetadataEdits()
        if clearEdits { edits = MetadataEdits() }
        for assignment in sets { try Self.apply(assignment, to: &edits) }
        let changed = clearEdits || !sets.isEmpty
        if folder == nil, !edits.tracks.isEmpty, changed {
            throw ValidationError("A track's names are kept with the rip: give its folder with -i.")
        }
        print()
        ReleaseChoice.printTracks(of: edits.applied(to: chosen, toc: toc), toc: toc)
        if !edits.isEmpty { print("Edited: " + Self.describe(edits)) }

        guard let folder else {
            if changed, !chosen.isManual {
                try store.remember(edits, forReleaseID: chosen.id)
                print("Kept the album's names for the release, for each of its discs.")
            }
            return
        }
        try chosen.save(inDiscJSONOf: folder)
        try edits.save(inDiscJSONOf: folder)
        if changed, !chosen.isManual { try store.remember(edits, forReleaseID: chosen.id) }
        print()
        print(
            "Saved the release" + (edits.isEmpty ? "" : " and the edits")
                + " in \(folder.appending(path: "disc.json").path).")
        let image = try cover.map { try CoverImage(converting: try Data(contentsOf: URL(filePath: $0))) }
        if let image {
            print("Cover: \(try image.write(to: folder).path)")
        } else if !chosen.isManual {
            ReleaseChoice.printArtwork(
                try await CoverArtClient().saveArtwork(artwork ?? Settings.load().artwork, of: chosen, in: folder))
        }
        if retag {
            let settings = try Settings.load()
            let written = try DiscEncoder(settings: settings).retag(
                reportAt: folder.appending(path: "disc.json"), cover: image, library: settings.libraryURL)
            print(
                written.isEmpty
                    ? "Not encoded yet: the names and the cover go into the files when it is."
                    : "Wrote the tags of \(written.count) encoded files.")
        }
    }
}

extension Metadata {
    /// Applies one `--set key=value`.
    static func apply(_ assignment: String, to edits: inout MetadataEdits) throws {
        guard let equals = assignment.firstIndex(of: "=") else {
            throw ValidationError("--set needs key=value, not \"\(assignment)\".")
        }
        let key = assignment[..<equals].trimmingCharacters(in: .whitespaces)
        let text = String(assignment[assignment.index(after: equals)...])
        let value: String? = text.isEmpty ? nil : text
        switch key {
        case "album": edits.album = value
        case "albumArtist", "artist": edits.albumArtist = value
        case "date", "year": edits.date = value
        default:
            let parts = key.split(separator: ".")
            guard parts.count == 2, parts[0].hasPrefix("track"), let number = Int(parts[0].dropFirst(5)) else {
                throw ValidationError(
                    "Unknown key \"\(key)\": use album, albumArtist, date, trackN.title, or trackN.artist.")
            }
            switch parts[1] {
            case "title": edits.setTitle(value, ofTrack: number)
            case "artist": edits.setArtist(value, ofTrack: number)
            default: throw ValidationError("Unknown key \"\(key)\": a track has title and artist.")
            }
        }
    }

    static func describe(_ edits: MetadataEdits) -> String {
        var parts = [String]()
        if edits.album != nil { parts.append("album") }
        if edits.albumArtist != nil { parts.append("album artist") }
        if edits.date != nil { parts.append("date") }
        for number in edits.tracks.keys.sorted() {
            if edits.tracks[number]?.title != nil { parts.append("track \(number) title") }
            if edits.tracks[number]?.artist != nil { parts.append("track \(number) artist") }
        }
        return parts.joined(separator: ", ")
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
            let composers =
                track.composers.isEmpty ? "" : "  (\(track.composers.map(\.tagName).joined(separator: ", ")))"
            print(String(format: "  %2d  %@  ", track.position, length) + artist + track.title + composers)
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
