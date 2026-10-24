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

            Examples:
              silverside encode -i "Grateful Dead - Cornell 5-8-77 (Disc 1)" -i "... (Disc 2)" -i "... (Disc 3)"
              silverside encode -i <folder> --format alac --library /Volumes/storage/Music
              silverside encode -i <folder> --format mp3 --mp3-mode cbr --mp3-bitrate 320
              silverside encode -i <folder> --format aac --aac-mode cbr --aac-bitrate 192
            """)

    @Option(name: .shortAndLong, help: "A rip's folder. Give it once for each disc.")
    var input: [String]

    @OptionGroup var encoding: EncodingOptions

    @Flag(help: "Encode tracks that AccurateRip and CTDB do not prove.")
    var allowUnverified = false

    func validate() throws {
        if input.isEmpty { throw ValidationError("Give at least one --input folder.") }
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
        var total = 0
        for folder in input.map({ URL(filePath: $0, directoryHint: .isDirectory) }) {
            let disc = try RippedDisc(folder: folder)
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
}
