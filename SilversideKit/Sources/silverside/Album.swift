import ArgumentParser
import Foundation
import SilversideKit

struct Album: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Put a release's tags and cover art into an album folder that Silverside did not rip.",
        discussion: """
            The folder holds one release: a disc, or every disc of a set, as FLAC or Apple Lossless and AAC (.m4a) \
            files. Keep one format in the folder: every audio file counts as a track, so FLAC and MP3 copies side by \
            side fit no release. Silverside finds the release: the one named with --release, else the one kept in the folder by an \
            earlier run, else the files' MusicBrainz Album Id tag, else a MusicBrainz search by the files' album and \
            artist (or the folder's names), with their track lengths deciding. When a search finds more than one \
            release that fits, you choose.

            It shows every change first, tag by tag, with links to the images, and asks before it writes. Each file \
            gets the release's tags, as an encoding from a rip writes them (with your naming settings), over its \
            own: each tag that Silverside writes replaces the file's, and every other tag stays. It gets the cover \
            too (1000 pixels at most). Its audio is checked, and stays as it was. The folder gets the cover at full \
            size (cover.jpg), and with --artwork the release's other images in Artwork/. The choice is kept in the \
            folder, in .silverside-album.json.

            Examples:
              silverside album "~/Music/The Beatles/Abbey Road"
              silverside album <folder> --release c93e1d4c-89fa-3139-9c65-8542a39f07d1 --list
              silverside album <folder> --sheet ~/Desktop/sheet.jpg
              silverside album <folder> --front 3 --artwork all
              silverside album <folder> --front ~/Downloads/scan.jpg
              silverside album <folder> --artwork 4-10,12 --dry-run
              silverside album <folder> --no-cover
            """)

    @Argument(help: "The album folder.", completion: .directory)
    var folder: String

    @Option(help: "The release: its MusicBrainz ID, or its page's URL.")
    var release: String?

    @Option(help: "Words to search MusicBrainz for, in place of the files' album and artist.")
    var search: String?

    @Option(
        help:
            "The image to use as the cover: its number in --list, its Cover Art Archive ID, or an image file. By default, the release's front."
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

    @Flag(help: "Leave the tags as they are: the cover and the artwork only.")
    var noTags = false

    @Flag(help: "Leave the covers and Artwork as they are: the tags only.")
    var noCover = false

    @Flag(
        help: """
            Write the tags even when the track lengths do not agree with the files', or MusicBrainz has none: the \
            files pair with the tracks by their order, when there are as many. The choice keeps it for later runs.
            """)
    var forceFit = false

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
        // An image file is checked before the search, so a wrong path costs no lookup.
        let frontFile = try front.flatMap(Self.frontFile)

        let finder = AlbumReleaseFinder()
        let found = try await finder.find(for: album, releaseID: release, search: search)
        let chosen = try choose(found, album: album)
        if case .search = chosen.source {
            print("Looking up the release's credits and composers...")
        }
        let candidate = try await finder.complete(chosen)
        // The files pair with the tracks by their order: asked for now, or kept from a run that was.
        let byOrder =
            forceFit || (album.choice?.releaseID == candidate.release.id && album.choice?.byOrder == true)
        print()
        Self.printRelease(candidate, album: album, byOrder: byOrder)

        let client = CoverArtClient()
        let looksAtImages = !noCover || list || sheet != nil
        let images = looksAtImages ? try await client.images(releaseID: candidate.release.id) : []
        // The folder's own cover: given now, or chosen with a file in an earlier run.
        let ownCover =
            frontFile != nil
            || (front == nil && album.choice?.releaseID == candidate.release.id && album.choice?.ownCover == true
                && album.coverFile != nil)
        if looksAtImages, images.isEmpty, list || sheet != nil || (noTags && !ownCover) {
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

        var artworkPlan: AlbumArtworkPlan?
        if !noCover, !images.isEmpty || ownCover {
            artworkPlan = try await AlbumArtworkPlan.make(
                album: album, release: candidate.release, media: candidate.fit?.media,
                front: try frontFile == nil ? front.map { try Self.imageID($0, in: images) } : nil,
                frontFile: frontFile,
                artwork: try artwork.map { try Self.selection($0, in: images) }, client: client)
        }
        var tagsPlan: AlbumTagsPlan?
        if !noTags {
            // Tags need each file paired with its track: by the lengths, or with --force-fit by the order.
            let fit =
                candidate.fit.flatMap { $0.kind == .lengths || byOrder ? $0 : nil }
                ?? (byOrder ? candidate.release.fit(lengths: album.lengths, byOrder: true) : nil)
            if let fit {
                let settings = try Settings.load()
                var made = AlbumTagsPlan.make(album: album, release: candidate.release, fit: fit, settings: settings)
                let title = try Self.askAlbumTitle(made)
                if title != made.albumTitle {
                    made = AlbumTagsPlan.make(
                        album: album, release: candidate.release, fit: fit, settings: settings, albumTitle: title)
                }
                tagsPlan = made
            } else {
                print()
                print(
                    candidate.fit != nil
                        ? "Tags: not written. MusicBrainz has no track lengths to compare; --force-fit pairs the files with the tracks by their order."
                        : candidate.release.fit(lengths: album.lengths, byOrder: true) != nil
                            ? "Tags: not written. Some track lengths do not agree with the files' (marked above); --force-fit pairs the files with the tracks by their order."
                            : "Tags: not written. The release does not fit the files, so which file is which track is not known."
                )
            }
        }
        let plan = AlbumPlan(album: album, release: candidate.release, artwork: artworkPlan, tags: tagsPlan)
        if let artworkPlan {
            print()
            Self.printPlan(artworkPlan, images: images)
        } else if !noCover {
            print()
            print("Cover: the Cover Art Archive has no images for this release, so the covers stay as they are.")
        }
        if let tagsPlan {
            print()
            Self.printTags(tagsPlan)
        }
        if noTags {
            print()
            print("Tags: left as they are (--no-tags).")
        }
        print()
        guard plan.hasChanges else {
            print("Nothing to change.")
            return
        }
        if let artworkPlan { Self.printEmbedWarning(artworkPlan) }
        Self.printID3Note(plan)
        print("The choice goes in \(AlbumChoice.fileName).")
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
            case .skippedFileInUse(let file):
                print("  \(file.lastPathComponent): open in another program, left as it is")
            case .wroteCover(let file): print("Cover: \(file.path)")
            case .wroteArtwork(let count): print("Artwork: " + Self.images(count))
            case .keptOriginal(let file): print("Kept the old one as \(file.lastPathComponent).")
            case .keptChoice(let file): print("Kept the choice in \(file.lastPathComponent).")
            }
        }
        print("Done.")
    }

    /// The release to use: the finder's, else one the user picks from what the search found.
    func choose(_ found: AlbumReleaseFinder.Result, album: LibraryAlbum) throws -> AlbumReleaseCandidate {
        if let chosen = found.chosen { return chosen }
        let searched = found.searched.map { " (searched for \($0))" } ?? ""
        let busy =
            found.unavailable.isEmpty
            ? ""
            : (found.unavailable.count == 1 ? "1 release" : "\(found.unavailable.count) releases")
                + " that may fit could not be looked up: MusicBrainz is busy. Run the command again later"
        guard !found.candidates.isEmpty else {
            if !busy.isEmpty { throw CommandError(busy + ".") }
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
        if !busy.isEmpty { print("  " + busy + " to include them.") }
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

    /// The album name for the tags: the files' names now, and the release's, then a line to
    /// edit with the name the tags would get (one kept from an earlier run, else the release's).
    static func askAlbumTitle(_ plan: AlbumTagsPlan) throws -> String {
        let writable = plan.files.filter(\.canWrite)
        guard !writable.isEmpty else { return plan.albumTitle }
        var now = [String]()
        for file in writable {
            if let value = file.file.tag("ALBUM"), !value.isEmpty, !now.contains(value) { now.append(value) }
        }
        print()
        print("Album name in the tags (edit it and press Return; ↑ and ↓ go through these names):")
        let width = 13
        if now.isEmpty { print("  " + "Now".padding(toLength: width, withPad: " ", startingAt: 0) + "(none)") }
        for (index, value) in now.enumerated() {
            print("  " + (index == 0 ? "Now" : "").padding(toLength: width, withPad: " ", startingAt: 0) + value)
        }
        print("  " + "MusicBrainz".padding(toLength: width, withPad: " ", startingAt: 0) + plan.releaseAlbumTitle)
        var choices = [plan.albumTitle]
        for name in now + [plan.releaseAlbumTitle] where !choices.contains(name) { choices.append(name) }
        let edited: String
        do {
            edited = try LineEditor.read(
                prompt: "  " + "New".padding(toLength: width, withPad: " ", startingAt: 0), text: plan.albumTitle,
                choices: choices)
        } catch is LineEditor.Stopped {
            throw CommandError("Stopped: nothing written.")
        }
        let trimmed = edited.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? plan.albumTitle : trimmed
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
        throw CommandError(
            images.isEmpty
                ? "The Cover Art Archive has no images for this release, so there is no image \(trimmed). Give an image file."
                : "The release has no image \(trimmed): use a number from 1 to \(images.count), an ID, or an image file."
        )
    }

    /// The image file that `--front` names, if it names one: a path (with a slash, or a file
    /// that exists here), not an image's number or ID. Checked to be an image now.
    static func frontFile(_ text: String) throws -> URL? {
        let path = (text as NSString).expandingTildeInPath
        let looksLikePath = text.contains("/") || (Int(text) == nil && FileManager.default.fileExists(atPath: path))
        guard looksLikePath else { return nil }
        let url = URL(filePath: path).standardizedFileURL
        guard let data = try? Data(contentsOf: url) else {
            throw CommandError("--front: \(url.path) cannot be read.")
        }
        guard (try? CoverImage(converting: data)) != nil else {
            throw CommandError("--front: \(url.path) is not an image that macOS reads.")
        }
        return url
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

    static func printRelease(_ candidate: AlbumReleaseCandidate, album: LibraryAlbum, byOrder: Bool) {
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
        // As many tracks as files, but lengths that do not agree: the pairing by order, to judge by.
        guard let fit = candidate.fit ?? candidate.release.fit(lengths: album.lengths, byOrder: true) else {
            let counts = candidate.release.media.map { String($0.tracks.count) }.joined(separator: " + ")
            print("  Warning: it does not fit the files: \(album.files.count) files; its discs have \(counts) tracks.")
            return
        }
        if fit.kind == .order {
            let known = zip(fit.tracks, album.files).filter { $0.0.length != nil && $0.1.milliseconds != nil }.count
            print(
                "  Warning: \(fit.disagreeing.count) of the \(known) track lengths that MusicBrainz has differ from the"
                    + " files' by more than \(MusicBrainzRelease.lengthTolerance), marked below"
                    + (byOrder
                        ? ". The files pair with the tracks in this order (--force-fit)."
                        : ", so this may not be the files' release. --force-fit pairs them in this order."))
        }
        print("  " + fitText(fit))
        let disagreeing = Set(fit.disagreeing)
        let positions = fit.media.flatMap { position in
            (candidate.release.media.first { $0.position == position }?.tracks ?? []).map { (position, $0.position) }
        }
        // File names as macOS keeps them have "é" as two code points; precomposed, each is one column.
        let names = album.files.map { $0.url.lastPathComponent.precomposedStringWithCanonicalMapping }
        let width = min(44, names.map(\.count).max() ?? 0)
        for (index, file) in album.files.enumerated() {
            let track = fit.tracks[index]
            let place = fit.media.count > 1 ? "\(positions[index].0)-\(positions[index].1)" : "\(positions[index].1)"
            let name = padded(String(names[index].prefix(width)), width)
            let difference =
                track.length.flatMap { listed in
                    file.milliseconds.map { String(format: "%+.1f s", Double($0 - listed) / 1000) }
                } ?? ""
            let note = disagreeing.contains(index) ? ", does not agree" : ""
            print(
                "  " + padded(place, 5) + name + "  " + padded(duration(file.milliseconds), 6) + "  "
                    + track.title + "  " + duration(track.length)
                    + (difference.isEmpty ? "" : "  (\(difference)\(note))"))
        }
    }

    /// Text and spaces after it to `width` characters. `padding(toLength:)` counts UTF-16
    /// units, so a name with a decomposed "é" came out one column short.
    static func padded(_ text: String, _ width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
    }

    static func printImages(_ images: [CoverArtImage]) {
        print("The Cover Art Archive's images of the release:")
        for (index, image) in images.enumerated() {
            print(String(format: "%4d. ", index + 1) + label(image, number: nil) + "  " + image.url.absoluteString)
        }
    }

    static func printPlan(_ plan: AlbumArtworkPlan, images: [CoverArtImage]) {
        if let front = plan.front {
            let number = (images.firstIndex { $0.id == front.id } ?? 0) + 1
            print(
                "Cover: image \(number), " + label(front, number: nil) + ", \(plan.coverPicture.summary)"
                    + (plan.frontIsSleeve ? " (this disc's own sleeve in the set)" : ""))
            print("  \(front.url.absoluteString)")
        } else if let file = plan.frontFile {
            let inFolder = file.deletingLastPathComponent().standardizedFileURL == plan.album.folder.standardizedFileURL
            print(
                "Cover: " + (inFolder ? "the folder's own, \(file.lastPathComponent)" : file.path)
                    + ", \(plan.coverPicture.summary)")
            print("  \(file.absoluteString)")
        }
        print()
        print("Cover changes:")
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
            let name = plan.album.coverFile?.lastPathComponent ?? "the cover file"
            let summary = old.map { " (\($0.summary))" } ?? ""
            if plan.album.coverFile.map(AlbumArtworkPlan.isCoverName) ?? true {
                print(
                    "  Replace \(name)\(summary) with the full-size cover"
                        + (plan.keptCoverFile.map { "; the old one is kept as \($0.lastPathComponent)." } ?? "."))
            } else {
                print(
                    "  Write cover.\(plan.cover.fileExtension ?? "jpg") (\(plan.coverPicture.summary)); \(name)\(summary) "
                        + (plan.keptCoverFile.map { "is kept as \($0.lastPathComponent)." } ?? "stays as it is."))
            }
        case .unchanged: print("  The cover file is this cover already.")
        }
        switch plan.artwork {
        case .leave:
            let others = plan.images.filter { $0.id != plan.front?.id }.count
            print(
                "  Artwork: left as it is"
                    + (others == 0
                        ? "."
                        : " (--artwork all saves the release's "
                            + (others == 1 ? "other image)." : "\(others) other images).")))
        case .unchanged:
            print("  Artwork: these images already.")
        case .replace(let chosen):
            print(
                "  Artwork: "
                    + (plan.album.artworkCount > 0 ? "replace its \(plan.album.artworkCount) images with" : "save")
                    + " \(chosen.count) images"
                    + (plan.keptArtwork.map { " (the old ones are kept in \($0.lastPathComponent))" } ?? "") + ":")
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
    }

    /// A warning, just before the question, that the files' own embedded covers are replaced and not kept.
    static func printEmbedWarning(_ plan: AlbumArtworkPlan) {
        let replaced = plan.files.compactMap { file -> LibraryAlbum.Picture? in
            if case .embed(let old) = file.change { old } else { nil }
        }
        guard !replaced.isEmpty else { return }
        let sizes = Set(replaced.map(\.summary))
        let files = replaced.count == 1 ? "1 file's embedded cover" : "\(replaced.count) files' embedded covers"
        print(
            "Warning: \(files) (" + (sizes.count == 1 ? sizes.first! : "of \(sizes.count) sizes")
                + ") will be replaced, and not kept.")
    }

    /// The ID3 tags before the FLAC data that the write leaves out, as Exact Audio Copy writes them.
    static func printID3Note(_ plan: AlbumPlan) {
        let count = plan.rewrittenFiles.filter(\.hasLeadingID3).count
        guard count > 0 else { return }
        print(
            (count == 1 ? "1 FLAC file has" : "\(count) FLAC files have")
                + " an ID3 tag before the FLAC data, as Exact Audio Copy writes one. FLAC players read the Vorbis"
                + " comments, and its old names would disagree with the new tags, so the write leaves it out.")
    }

    /// The tags' changes: the album's once, then each file's, then what goes and what stays.
    static func printTags(_ plan: AlbumTagsPlan) {
        let writable = plan.files.filter(\.canWrite)
        print(
            "Tags: the release's, over the files' own" + (writable.isEmpty ? "" : ", in \(writable.count) files") + ":")
        guard plan.hasChanges else {
            print("  The files have the release's tags already.")
            printLeftAlone(plan)
            return
        }
        let shared = plan.sharedChanges
        let width =
            (writable.flatMap(\.changes).map(\.key.count).max() ?? 0) + 2
        if !shared.isEmpty {
            print("  In every file:")
            for change in shared { printChange(change, indent: 4, width: width) }
        }
        let own = writable.map { file in (file, file.changes.filter { !shared.contains($0) }) }
        if own.contains(where: { !$0.1.isEmpty }) {
            print(writable.count == 1 ? "  The file:" : "  Each file:")
            for (file, changes) in own where !changes.isEmpty {
                print("    \(file.file.url.lastPathComponent)")
                for change in changes { printChange(change, indent: 6, width: width) }
            }
        }
        if writable.contains(where: \.otherRelease) {
            print("  The files named another release in MusicBrainz: its own tags go (above, as removed).")
        }
        let kept = plan.keptKeys
        if !kept.isEmpty { print("  Kept as they are: " + kept.joined(separator: ", ")) }
        printLeftAlone(plan)
    }

    static func printLeftAlone(_ plan: AlbumTagsPlan) {
        let left = plan.files.filter { !$0.canWrite }
        guard !left.isEmpty else { return }
        let kinds = Set(left.map { $0.file.url.pathExtension.uppercased() }).sorted().joined(separator: ", ")
        print("  Left alone: \(left.count) files (\(kinds)), whose tags Silverside cannot write yet.")
    }

    /// "ALBUM  They Want My Soul (180g Clear Vinyl) → They Want My Soul  (was album)".
    static func printChange(_ change: TagMerge.Change, indent: Int, width: Int) {
        func values(_ list: [String]) -> String {
            list.isEmpty
                ? "(none)" : list.map { $0.count > 80 ? String($0.prefix(80)) + "..." : $0 }.joined(separator: "; ")
        }
        let was = change.oldNames.isEmpty ? "" : "  (was " + change.oldNames.joined(separator: ", ") + ")"
        let text: String
        if change.isRemoved {
            text = values(change.old) + " → (removed)"
        } else if change.isRenamedOnly {
            text = values(change.new)
        } else {
            text = values(change.old) + " → " + values(change.new)
        }
        print(
            String(repeating: " ", count: indent) + change.key.padding(toLength: width, withPad: " ", startingAt: 0)
                + text
                + was)
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
        case .order:
            return
                "By order: \(fit.tracks.count) tracks of \(discs), \(fit.disagreeing.count) lengths that do not agree"
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
