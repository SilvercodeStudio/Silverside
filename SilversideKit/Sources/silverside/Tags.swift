import ArgumentParser
import Foundation
import SilversideKit

struct Tags: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Summarize the audio files and tags of album folders, or of some files.",
        discussion: """
            For each folder: its files with their format, length, and size; the tags that every file has, once, \
            then each file's own; the embedded covers, the cover file, Artwork, and the choice that silverside \
            album keeps. It reads FLAC, Apple Lossless and AAC (.m4a), and MP3 tags itself, and other files' tags \
            through macOS. Nothing is changed, and nothing is looked up.

            Examples:
              silverside tags "~/Music/The Beatles/Abbey Road"
              silverside tags "~/Music/The Beatles" --recursive
              silverside tags "01 Come Together.m4a" --full
              silverside tags <folder> --json
            """)

    @Argument(help: "Album folders, or audio files.", completion: .file())
    var paths: [String]

    @Flag(name: .shortAndLong, help: "Each folder under the folders that has audio files, too.")
    var recursive = false

    @Flag(help: "Show long values in full, such as lyrics, and players' own items, such as iTunes's gapless data.")
    var full = false

    @Flag(help: "Print JSON.")
    var json = false

    func run() throws {
        var albums = [LibraryAlbum]()
        var looseFiles = [URL: [URL]]()
        for path in paths {
            let url = URL(filePath: (path as NSString).expandingTildeInPath)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
                throw ValidationError("\(url.path) does not exist.")
            }
            if isFolder.boolValue {
                let folders = recursive ? LibraryAlbum.audioFolders(under: url) : [url]
                for folder in folders { albums.append(try LibraryAlbum.read(folder)) }
                if !recursive, albums.last?.files.isEmpty == true, !LibraryAlbum.audioFolders(under: url).isEmpty {
                    albums.removeLast()
                    print("\(url.path) has no audio files, but folders in it do: add --recursive.")
                }
            } else {
                looseFiles[url.deletingLastPathComponent(), default: []].append(url)
            }
        }
        for (folder, files) in looseFiles.sorted(by: { $0.key.path < $1.key.path }) {
            albums.append(LibraryAlbum.read(files, in: folder))
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(albums.map(FolderReport.init)), as: UTF8.self))
            return
        }
        for (index, album) in albums.enumerated() {
            if index > 0 { print() }
            printAlbum(album)
        }
    }

    func printAlbum(_ album: LibraryAlbum) {
        print(album.folder.path)
        guard !album.files.isEmpty else {
            print("  No audio files.")
            return
        }
        let total = album.files.compactMap(\.milliseconds).reduce(0, +)
        let bytes = album.files.map(\.bytes).reduce(0, +)
        print(
            "  \(album.files.count) file\(album.files.count == 1 ? "" : "s"), \(Album.duration(total)), \(Self.size(bytes))"
        )
        let formats = Set(album.files.map { $0.format?.summary ?? "not read" })
        let sameFormat = formats.count == 1
        if sameFormat { print("  Format: \(formats.first!)" + (album.files.count > 1 ? " (every file)" : "")) }
        let id3 = album.files.filter(\.hasLeadingID3).count
        if id3 > 0 {
            print(
                "  ID3 tag before the FLAC data: "
                    + (id3 == album.files.count && id3 > 1 ? "every file" : "\(id3) of \(album.files.count) files")
                    + " (FLAC players read the Vorbis comments; silverside album leaves it out)")
        }
        let covers = album.files.compactMap(\.cover)
        let sameCover =
            covers.isEmpty || (covers.count == album.files.count && Set(covers.map(\.fingerprint)).count == 1)
        print(
            "  Embedded cover: "
                + (covers.isEmpty
                    ? "none"
                    : sameCover
                        ? covers[0].summary + (album.files.count > 1 ? " (the same in every file)" : "")
                        : "\(covers.count) of \(album.files.count) files, \(Set(covers.map(\.fingerprint)).count) different")
        )
        print(
            "  Cover file: "
                + (album.coverFile.map { "\($0.lastPathComponent), \(album.coverPicture?.summary ?? "not read")" }
                    ?? "none"))
        print("  Artwork: " + Album.images(album.artworkCount))
        if let choice = album.choice {
            print("  silverside album: release \(choice.releaseID)" + (choice.release.map { " (\($0))" } ?? ""))
        }

        let summary = album.tagSummary(technical: full)
        // Wide enough for the longest key (MUSICBRAINZ_RELEASEGROUPID), so the values line up.
        let keyWidth = ((summary.shared + summary.files.flatMap { $0 }).map(\.key.count).max() ?? 0) + 2
        if !summary.shared.isEmpty {
            print()
            print("  Tags in every file:")
            for tag in summary.shared { printTag(tag, indent: 4, width: keyWidth) }
        }
        print()
        if summary.shared.isEmpty, summary.files.allSatisfy(\.isEmpty) {
            print("  No tags" + (album.files.count == 1 ? ":" : " in any file:"))
            for file in album.files {
                print("    \(file.url.lastPathComponent)  \(Album.duration(file.milliseconds))")
            }
            printHidden(summary, files: album.files.count)
            return
        }
        print(album.files.count == 1 ? "  Tags:" : "  Each file:")
        for (file, tags) in zip(album.files, summary.files) {
            var line = "    \(file.url.lastPathComponent)  \(Album.duration(file.milliseconds))"
            if !sameFormat { line += "  \(file.format?.summary ?? "format not read")" }
            if !sameCover { line += "  cover: " + (file.cover?.summary ?? "none") }
            print(line)
            if tags.isEmpty {
                print("      " + (summary.shared.isEmpty ? "(no tags)" : "(only the tags above)"))
            }
            for tag in tags { printTag(tag, indent: 6, width: keyWidth) }
        }
        printHidden(summary, files: album.files.count)
    }

    /// The technical items left out, if any: "Left out (--full shows them): iTunSMPB (every file)".
    func printHidden(_ summary: LibraryAlbum.TagSummary, files: Int) {
        guard !summary.hidden.isEmpty else { return }
        let items = summary.hidden.map {
            $0.files == files && files > 1 ? "\($0.key) (every file)" : "\($0.key) (\($0.files) of \(files))"
        }
        print()
        print("  Left out (--full shows them): " + items.joined(separator: ", "))
    }

    func printTag(_ tag: LibraryAlbum.TagSummary.Tag, indent: Int, width: Int) {
        let pad = String(repeating: " ", count: indent)
        for (index, value) in tag.values.enumerated() {
            let key = index == 0 ? tag.key : ""
            print(pad + key.padding(toLength: max(width, key.count + 1), withPad: " ", startingAt: 0) + shown(value))
        }
    }

    /// A value on one line: its first line, cut at 100 characters, unless --full.
    func shown(_ value: String) -> String {
        guard !full else { return value }
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
        let first = String(lines.first ?? "")
        let more = lines.count > 1 ? " (\(lines.count) lines)" : ""
        return first.count > 100 ? String(first.prefix(100)) + "..." + more : first + more
    }

    static func size(_ bytes: Int) -> String {
        bytes >= 1_000_000_000
            ? String(format: "%.2f GB", Double(bytes) / 1e9) : String(format: "%.1f MB", Double(bytes) / 1e6)
    }
}

/// `silverside tags --json`: one folder.
private struct FolderReport: Encodable {
    struct Picture: Encodable {
        var bytes: Int
        var width: Int?
        var height: Int?
        var format: String?

        init(_ picture: LibraryAlbum.Picture) {
            (bytes, width, height, format) = (picture.bytes, picture.width, picture.height, picture.format)
        }
    }
    struct Format: Encodable {
        var name: String
        var sampleRate: Double
        var channels: Int
        var bits: Int?
        var bitRate: Int?
    }
    struct File: Encodable {
        var file: String
        var milliseconds: Int?
        var bytes: Int
        var format: Format?
        /// Each tag as [key, value], in the file's order.
        var tags: [[String]]
        var cover: Picture?
        /// True for a FLAC file with an ID3v2 tag before its FLAC data; left out otherwise.
        var leadingID3: Bool?
    }

    var folder: String
    var files: [File]
    var coverFile: String?
    var coverPicture: Picture?
    var artworkCount: Int
    var releaseID: String?

    init(_ album: LibraryAlbum) {
        folder = album.folder.path
        files = album.files.map { file in
            File(
                file: file.url.lastPathComponent, milliseconds: file.milliseconds, bytes: file.bytes,
                format: file.format.map {
                    Format(
                        name: $0.name, sampleRate: $0.sampleRate, channels: $0.channels, bits: $0.bits,
                        bitRate: $0.bitRate)
                }, tags: file.tags.map { [$0.key, $0.value] }, cover: file.cover.map(Picture.init),
                leadingID3: file.hasLeadingID3 ? true : nil)
        }
        coverFile = album.coverFile?.lastPathComponent
        coverPicture = album.coverPicture.map(Picture.init)
        artworkCount = album.artworkCount
        releaseID = album.choice?.releaseID
    }
}
