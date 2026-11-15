import ArgumentParser
import Foundation
import SilversideKit

struct Album: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Put a release's cover art into an album folder that Silverside did not rip.",
        discussion: """
            The folder holds one release: a disc, or every disc of a set, as FLAC or Apple Lossless and AAC (.m4a) \
            files. Silverside finds the release: the one named with --release, else the one kept in the folder by an \
            earlier run, else the files' MusicBrainz Album Id tag, else a MusicBrainz search by the files' album and \
            artist (or the folder's names), with their track lengths deciding. When a search finds more than one \
            release that fits, you choose.

            It shows every change first, with links to the images, and asks before it writes. Each file gets the \
            cover (1000 pixels at most), and keeps every other tag; its audio is checked, and stays as it was. The \
            folder gets the cover at full size (cover.jpg), and with --artwork the release's other images in \
            Artwork/. The choice is kept in the folder, in .silverside-album.json.

            Examples:
              silverside album "~/Music/The Beatles/Abbey Road"
              silverside album <folder> --release c93e1d4c-89fa-3139-9c65-8542a39f07d1 --list
              silverside album <folder> --sheet ~/Desktop/sheet.jpg
              silverside album <folder> --front 3 --artwork all
              silverside album <folder> --artwork 4-10,12 --dry-run
            """)

    @Argument(help: "The album folder.", completion: .directory)
    var folder: String

    @Option(help: "The release: its MusicBrainz ID, or its page's URL.")
    var release: String?

    @Option(help: "Words to search MusicBrainz for, in place of the files' album and artist.")
    var search: String?

    @Option(
        help:
            "The image to use as the cover: its number in --list, or its Cover Art Archive ID. By default, the release's front."
    )
    var front: String?

    @Option(
        help:
            "Images to save in Artwork/: all (every image but the cover), or numbers in --list and IDs, such as 4-10,12."
    )
    var artwork: String?

    @Flag(help: "List the release's images, with their numbers and links, and stop.")
    var list = false

    @Option(help: "Write a contact sheet of the release's images to this file (JPEG), and stop.", completion: .file())
    var sheet: String?

    @Flag(help: "Show what would change, and write nothing.")
    var dryRun = false

    @Flag(name: .shortAndLong, help: "Write without asking.")
    var yes = false

    func run() async throws {
        let url = URL(filePath: (folder as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        let album = try LibraryAlbum.read(url)
        guard !album.files.isEmpty else {
            throw CommandError("\(url.path) has no audio files. A set's discs in subfolders go one folder at a time.")
        }
        Self.printAlbum(album)

        let found = try await AlbumReleaseFinder().find(for: album, releaseID: release, search: search)
        let candidate = try choose(found, album: album)
        print()
        Self.printRelease(candidate, album: album)

        let client = CoverArtClient()
        let images = try await client.images(releaseID: candidate.release.id)
        guard !images.isEmpty else {
            throw CommandError(
                "The Cover Art Archive has no images for this release. Try another release of the album with --release."
            )
        }
        if list || sheet != nil {
            print()
            Self.printImages(images)
            if let sheet { try await writeSheet(images, to: sheet, client: client) }
            return
        }

        let plan = try await AlbumArtworkPlan.make(
            album: album, release: candidate.release, media: candidate.fit?.media,
            front: try front.map { try Self.imageID($0, in: images) },
            artwork: try artwork.map { try Self.selection($0, in: images) }, client: client)
        print()
        Self.printPlan(plan, images: images)
        print()
        guard plan.hasChanges else {
            print("Nothing to change.")
            return
        }
        if dryRun {
            print("Dry run: nothing written.")
            return
        }
        guard yes || Self.ask("Write these changes?") else {
            print("Nothing written.")
            return
        }
        try await plan.apply(client: client) { step in
            switch step {
            case .downloadingArtwork(let count): print("Downloading \(count) images for Artwork...")
            case .wroteFile(let file): print("  \(file.lastPathComponent)")
            case .wroteCover(let file): print("Cover: \(file.path)")
            case .wroteArtwork(let count): print("Artwork: " + Self.images(count))
            case .keptChoice(let file): print("Kept the choice in \(file.lastPathComponent).")
            }
        }
        print("Done.")
    }

    /// The release to use: the finder's, else one the user picks from what the search found.
    func choose(_ found: AlbumReleaseFinder.Result, album: LibraryAlbum) throws -> AlbumReleaseCandidate {
        if let chosen = found.chosen { return chosen }
        let searched = found.searched.map { " (searched for \($0))" } ?? ""
        guard !found.candidates.isEmpty else {
            throw CommandError(
                "MusicBrainz found no release with \(album.files.count) tracks of these lengths\(searched). "
                    + "Name one with --release, or search for other words with --search.")
        }
        // A search's release is never used without the user's choice, even when it is the only
        // one that fits: another release of the album may have the cover the user wants.
        print()
        print((found.candidates.count == 1 ? "This release fits" : "These releases fit") + " the files\(searched):")
        for (index, candidate) in found.candidates.enumerated() {
            print(String(format: "%3d. ", index + 1) + Self.summary(of: candidate.release))
            let count = candidate.release.artworkCount ?? (candidate.release.hasFrontCover ? 1 : 0)
            let images = count == 0 ? "no images" : Self.images(count)
            print(
                "     " + Self.fitText(candidate.fit) + "; \(images)  "
                    + (candidate.release.pageURL?.absoluteString ?? ""))
        }
        guard isatty(STDIN_FILENO) != 0 else {
            throw CommandError("A search found the release: choose it at a terminal, or name it with --release.")
        }
        while true {
            print("Which release? (a number, or Return to stop) ", terminator: "")
            fflush(stdout)
            let line = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
            if line.isEmpty { throw CommandError("No release chosen, so nothing is written.") }
            if let number = Int(line), found.candidates.indices.contains(number - 1) {
                return found.candidates[number - 1]
            }
            print("Give a number from 1 to \(found.candidates.count).")
        }
    }

    static func ask(_ question: String) -> Bool {
        guard isatty(STDIN_FILENO) != 0 else { return false }
        print("\(question) [y/N] ", terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return answer == "y" || answer == "yes"
    }

    func writeSheet(_ images: [CoverArtImage], to path: String, client: CoverArtClient) async throws {
        let progress = ProgressLine()
        var tiles = [CoverArtSheet.Tile]()
        for (index, image) in images.enumerated() {
            progress.showText("Thumbnails: \(index + 1) of \(images.count)")
            tiles.append(.init(label: Self.label(image, number: index + 1), image: try await client.thumbnail(image)))
        }
        progress.clear()
        let url = URL(filePath: (path as NSString).expandingTildeInPath)
        try CoverArtSheet.make(tiles).write(to: url, options: .atomic)
        print()
        print("Contact sheet: \(url.path)")
    }

    // MARK: - Choosing images

    /// An image's ID from its number in the list (1, 2, ...) or its ID.
    static func imageID(_ text: String, in images: [CoverArtImage]) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let image = images.first(where: { $0.id == trimmed }) { return image.id }
        if let number = Int(trimmed), images.indices.contains(number - 1) { return images[number - 1].id }
        throw ValidationError("The release has no image \(trimmed): use a number from 1 to \(images.count) or an ID.")
    }

    /// "all", or numbers, ranges, and IDs: "4-10,12".
    static func selection(_ text: String, in images: [CoverArtImage]) throws -> ArtworkSelection {
        if text.lowercased() == "all" { return .all }
        var ids = [String]()
        for part in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let bounds = part.split(separator: "-").map { Int($0) }
            if bounds.count == 2, let low = bounds[0], let high = bounds[1], low <= high {
                for number in low...high { ids.append(try imageID(String(number), in: images)) }
            } else {
                ids.append(try imageID(part, in: images))
            }
        }
        // Each image once, in the order given.
        var seen = Set<String>()
        return .images(ids.filter { seen.insert($0).inserted })
    }

    // MARK: - Printing

    static func printAlbum(_ album: LibraryAlbum) {
        print("Album folder: \(album.folder.path)")
        let total = album.files.compactMap(\.milliseconds).reduce(0, +)
        let kinds = Dictionary(album.files.map { ($0.url.pathExtension.lowercased(), 1) }, uniquingKeysWith: +)
            .sorted { $0.key < $1.key }.map { "\($0.value) \($0.key.uppercased())" }.joined(separator: ", ")
        print("  \(album.files.count) files (\(kinds)), \(duration(total))")
        let artist = album.commonTag("ALBUMARTIST") ?? album.commonTag("ARTIST")
        if let title = album.commonTag("ALBUM") {
            print("  Tags: " + [artist, title].compactMap { $0 }.joined(separator: " - "))
        } else {
            print("  Tags: no album name")
        }
        let covers = album.files.compactMap(\.cover)
        let sizes = Set(covers.map(\.summary))
        print(
            "  Embedded cover: \(covers.count) of \(album.files.count) files"
                + (sizes.count == 1 ? ", \(sizes.first!)" : sizes.isEmpty ? "" : ", of \(sizes.count) sizes"))
        print(
            "  Cover file: "
                + (album.coverFile.map { "\($0.lastPathComponent), \(album.coverPicture?.summary ?? "")" } ?? "none"))
        print("  Artwork: " + images(album.artworkCount))
        if let choice = album.choice {
            print("  Kept choice: release \(choice.releaseID), \(choice.program)")
        }
    }

    static func printRelease(_ candidate: AlbumReleaseCandidate, album: LibraryAlbum) {
        let source =
            switch candidate.source {
            case .given: "named with --release"
            case .kept: "kept in the folder"
            case .tags: "from the files' MusicBrainz Album Id"
            case .search: "found by a search"
            }
        print("Release (\(source)):")
        print("  " + summary(of: candidate.release))
        if let page = candidate.release.pageURL { print("  \(page.absoluteString)") }
        guard let fit = candidate.fit else {
            let counts = candidate.release.media.map { String($0.tracks.count) }.joined(separator: " + ")
            print("  Warning: it does not fit the files: \(album.files.count) files; its discs have \(counts) tracks.")
            return
        }
        print("  " + fitText(fit))
        let positions = fit.media.flatMap { position in
            (candidate.release.media.first { $0.position == position }?.tracks ?? []).map { (position, $0.position) }
        }
        let width = min(44, album.files.map(\.url.lastPathComponent.count).max() ?? 0)
        for (index, file) in album.files.enumerated() {
            let track = fit.tracks[index]
            let place = fit.media.count > 1 ? "\(positions[index].0)-\(positions[index].1)" : "\(positions[index].1)"
            let name = String(file.url.lastPathComponent.prefix(width)).padding(
                toLength: width, withPad: " ", startingAt: 0)
            let difference =
                track.length.flatMap { listed in
                    file.milliseconds.map { String(format: "%+.1f s", Double($0 - listed) / 1000) }
                } ?? ""
            print(
                "  " + place.padding(toLength: 5, withPad: " ", startingAt: 0) + name + "  "
                    + duration(file.milliseconds).padding(toLength: 6, withPad: " ", startingAt: 0) + "  "
                    + track.title + "  " + duration(track.length) + (difference.isEmpty ? "" : "  (\(difference))"))
        }
    }

    static func printImages(_ images: [CoverArtImage]) {
        print("The Cover Art Archive's images of the release:")
        for (index, image) in images.enumerated() {
            print(String(format: "%4d. ", index + 1) + label(image, number: nil) + "  " + image.url.absoluteString)
        }
    }

    static func printPlan(_ plan: AlbumArtworkPlan, images: [CoverArtImage]) {
        let number = (images.firstIndex { $0.id == plan.front.id } ?? 0) + 1
        print(
            "Cover: image \(number), " + label(plan.front, number: nil) + ", \(plan.coverPicture.summary)"
                + (plan.frontIsSleeve ? " (this disc's own sleeve in the set)" : ""))
        print("  \(plan.front.url.absoluteString)")
        print()
        print("Changes:")
        let embeds = plan.files.filter { if case .embed = $0.change { true } else { false } }
        if !embeds.isEmpty {
            print("  Embed the cover (\(plan.embeddedPicture.summary)) in \(embeds.count) files:")
            for file in embeds {
                guard case .embed(let old) = file.change else { continue }
                print(
                    "    \(file.file.url.lastPathComponent)  "
                        + (old.map { "in place of \($0.summary)" } ?? "(no cover now)"))
            }
        }
        let same = plan.files.filter { $0.change == .unchanged }.count
        if same > 0 { print("  \(same) files have this cover already.") }
        let unsupported = plan.files.filter { $0.change == .unsupported }
        if !unsupported.isEmpty {
            let kinds = Set(unsupported.map { $0.file.url.pathExtension.uppercased() }).sorted().joined(separator: ", ")
            print("  Left alone: \(unsupported.count) files (\(kinds)), which Silverside cannot write a cover in yet.")
        }
        switch plan.coverFile {
        case .write: print("  Write cover.\(plan.cover.fileExtension ?? "jpg") (\(plan.coverPicture.summary)).")
        case .replace(let old):
            print(
                "  Replace \(plan.album.coverFile?.lastPathComponent ?? "the cover file")"
                    + (old.map { " (\($0.summary))" } ?? "") + " with the full-size cover.")
        case .unchanged: print("  The cover file is this cover already.")
        }
        switch plan.artwork {
        case .leave:
            let others = plan.images.filter { $0.id != plan.front.id }.count
            print(
                "  Artwork: left as it is"
                    + (others > 0 ? " (--artwork all saves the release's \(others) other images)." : "."))
        case .unchanged:
            print("  Artwork: these images already.")
        case .replace(let chosen):
            print(
                "  Artwork: "
                    + (plan.album.artworkCount > 0 ? "replace its \(plan.album.artworkCount) images with" : "save")
                    + " \(chosen.count) images:")
            for item in chosen {
                let number = (images.firstIndex { $0.id == item.image.id } ?? 0) + 1
                print(
                    "    \(item.name)  (image \(number), \(label(item.image, number: nil)))  \(item.image.url.absoluteString)"
                )
            }
            if plan.otherDiscsImages > 0 {
                print(
                    "    Left out: \(plan.otherDiscsImages) images that name other discs of the set "
                        + "(give their numbers to --artwork to add them).")
            }
        }
        print("  Keep the choice in \(AlbumChoice.fileName).")
        print("  Every other tag stays as it is.")
    }

    /// "Artist - Title (1969, GB; Apple PCS 7088; barcode 0094638246817; CD)".
    static func summary(of release: MusicBrainzRelease) -> String {
        var details = [[release.date, release.country].compactMap { $0 }.joined(separator: ", ")]
        let labels = release.labels.map { [$0.name, $0.catalogNumber].compactMap { $0 }.joined(separator: " ") }
            .filter { !$0.isEmpty }
        if !labels.isEmpty { details.append(labels.joined(separator: ", ")) }
        if let barcode = release.barcode, !barcode.isEmpty { details.append("barcode \(barcode)") }
        details.append(release.formats)
        if let status = release.status, status != "Official" { details.append(status.lowercased()) }
        if let disambiguation = release.disambiguation, !disambiguation.isEmpty { details.append(disambiguation) }
        return "\(release.artist) - \(release.title) (\(details.filter { !$0.isEmpty }.joined(separator: "; ")))"
    }

    static func fitText(_ fit: AlbumFit?) -> String {
        guard let fit else { return "does not fit the files" }
        let discs = fit.media.count == 1 ? "disc \(fit.media[0])" : "discs \(fit.media.first!)-\(fit.media.last!)"
        switch fit.kind {
        case .lengths:
            let largest = fit.largestDifference.map { String(format: "%.1f", Double($0) / 1000) } ?? "0"
            return "Fits: \(fit.tracks.count) tracks of \(discs), lengths within \(largest) s"
        case .trackCountOnly:
            return "Fits: \(fit.tracks.count) tracks of \(discs), no lengths to compare"
        }
    }

    /// "Booklet, Medium (Disc 2)", or with a number, "12  Booklet ...", for the sheet.
    static func label(_ image: CoverArtImage, number: Int?) -> String {
        var text = image.types.isEmpty ? "No type" : image.types.joined(separator: ", ")
        if image.isFront { text += " (main front)" }
        if !image.comment.isEmpty { text += " - \(image.comment)" }
        return number.map { "\($0)  \(text)" } ?? text
    }

    /// "none", "1 image", "12 images".
    static func images(_ count: Int) -> String {
        count == 0 ? "none" : count == 1 ? "1 image" : "\(count) images"
    }

    static func duration(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "?:??" }
        let seconds = milliseconds / 1000
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
