import ArgumentParser
import Foundation
import SilversideKit

struct Encode: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Encode ripped discs into a music library, named and tagged from MusicBrainz.",
        discussion: """
            Each input is a rip's folder, from silverside rip or the archive, with a disc.json that has the release \
            (silverside metadata -i adds it). The files are checked after encoding: a lossless file must decode to the \
            ripped audio. Each disc of a release goes into the same album folder, as "18-03 Title.flac". Options \
            that are not given come from the settings (silverside config).

            An input can also be an album folder in the library whose files are lossless: it is encoded again from \
            those files, each checked first against the rip's CRC-32. So an HDCD disc kept as pressed can be decoded \
            later, beside the album (--hdcd-copy) or in its place (--hdcd decode --overwrite, in the album's format).

            Examples:
              silverside encode -i "Grateful Dead - Cornell 5-8-77 (Disc 1)" -i "... (Disc 2)" -i "... (Disc 3)"
              silverside encode -i <folder> --format alac --library /Volumes/storage/Music
              silverside encode -i <folder> --format mp3 --mp3-mode cbr --mp3-bitrate 320
              silverside encode -i <folder> --format aac --aac-mode cbr --aac-bitrate 192
              silverside encode -i "~/Music/Silverside Library/Grateful Dead/Dozin' at the Knick" --hdcd-copy
            """)

    @Option(name: .shortAndLong, help: "A rip's folder. Give it once for each disc.")
    var input: [String]

    @OptionGroup var encoding: EncodingOptions

    @Flag(help: "Encode tracks that AccurateRip and CTDB do not prove.")
    var allowUnverified = false

    @Flag(
        help: """
            Write the HDCD decode as an album of its own beside the album as it is, named "<album> (HDCD)". \
            Implies --hdcd decode.
            """)
    var hdcdCopy = false

    @Option(help: "With --hdcd-copy, what the copy's album title ends with, such as \"(HDCD AAC)\".")
    var hdcdCopySuffix = "(HDCD)"

    func validate() throws {
        if input.isEmpty { throw ValidationError("Give at least one --input folder.") }
        if hdcdCopy && hdcdCopySuffix.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError("The copy needs a name of its own: give --hdcd-copy-suffix some text.")
        }
    }

    func run() throws {
        let settings = try Settings.load()
        var (encoder, libraryURL) = encoding.encoder(settings)
        let format = encoder.format
        var addsToMusic = encoding.addsToMusic(settings)
        if addsToMusic && !MusicApp.reads(format) {
            print("Music cannot read \(format.name) files, so they are not added to it.")
            addsToMusic = false
        }
        var written = [URL]()
        encoder.allowsUnverified = allowUnverified
        encoder.log = { print("  \($0)") }
        if hdcdCopy {
            encoder.decodesHDCD = true
            encoder.albumSuffix = " " + hdcdCopySuffix.trimmingCharacters(in: .whitespaces)
        }
        var total = 0
        for disc in try input.flatMap({
            try Self.discs(in: URL(filePath: Settings.expand($0).path, directoryHint: .isDirectory))
        }) {
            let folder = disc.folder
            let medium = disc.release?.medium(for: disc.toc)
            var name = disc.release.map { "\($0.artist) - \($0.title)" } ?? folder.lastPathComponent
            if let medium, let release = disc.release, release.media.count > 1 { name += ", disc \(medium.position)" }
            print("\(name): \(disc.tracks.count) tracks")
            let files = try encoder.encode(disc, into: libraryURL)
            total += files.count
            written += files
            if let first = files.first { print("  in \(first.deletingLastPathComponent().path)") }
        }
        print("Encoded \(total) tracks as \(format.rawValue.uppercased()), each checked against the rip.")
        if addsToMusic {
            print("Added \(try MusicApp.add(written)) tracks to Music.")
        }
    }

    /// The discs in a folder: a rip (its disc.json), or an album in the library, whose
    /// "Rip Report (Disc N).json" files each make a disc of its encoded files.
    static func discs(in folder: URL) throws -> [RippedDisc] {
        if FileManager.default.fileExists(atPath: folder.appending(path: "disc.json").path) {
            return [try RippedDisc(folder: folder)]
        }
        let reports = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("Rip Report") && $0.hasSuffix(".json") }.sorted()
        guard !reports.isEmpty else { throw EncodingError.noDiscJSON(folder) }
        return try reports.map { try RippedDisc(albumReportAt: folder.appending(path: $0)) }
    }
}
