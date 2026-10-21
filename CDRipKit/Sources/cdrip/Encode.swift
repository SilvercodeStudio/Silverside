import ArgumentParser
import CDRipKit
import Foundation

struct Encode: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Encode ripped discs into a music library, named and tagged from MusicBrainz.",
        discussion: """
            Each input is a rip's folder, from cdrip rip or the archive, with a disc.json that has the release \
            (cdrip metadata -i adds it). The files are checked after encoding: a lossless file must decode to the \
            ripped audio. Each disc of a release goes into the same album folder, as "18-03 Title.flac".
            """)

    @Option(name: .shortAndLong, help: "A rip's folder. Give it once for each disc.")
    var input: [String]

    static let defaultLibrary = URL.musicDirectory.appending(path: "CDRip Library").path

    @Option(name: .shortAndLong, help: "The music library's folder.")
    var library: String = defaultLibrary

    @Option(help: "The format: \(AudioFormat.allCases.map(\.rawValue).joined(separator: ", ")).")
    var format: AudioFormat = .flac

    @Option(help: "The album folder's template, in the library.")
    var folderTemplate = NameTemplate.libraryFolder.pattern

    @Option(help: "Each track's file name template, with no extension.")
    var trackTemplate = NameTemplate.libraryTrack.pattern

    @Flag(help: "Do not add \"[Venue, M-D-YY]\" to titles, nor take dates from disc titles, for live shows.")
    var noLiveShowStyle = false

    @Option(help: "The AAC bit rate, in kbit/s.")
    var aacBitRate = AudioEncoder.defaultAACBitRate / 1000

    @Flag(help: "Encode tracks that AccurateRip and CTDB do not prove.")
    var allowUnverified = false

    @Flag(help: "Replace files that exist in the library.")
    var overwrite = false

    func validate() throws {
        if input.isEmpty { throw ValidationError("Give at least one --input folder.") }
    }

    func run() throws {
        let libraryURL = URL(filePath: (library as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        var encoder = DiscEncoder(format: format)
        encoder.folderTemplate = NameTemplate(folderTemplate)
        encoder.trackTemplate = NameTemplate(trackTemplate)
        encoder.liveShowStyle = !noLiveShowStyle
        encoder.aacBitRate = aacBitRate * 1000
        encoder.allowsUnverified = allowUnverified
        encoder.overwrites = overwrite
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
            if let first = files.first { print("  in \(first.deletingLastPathComponent().path)") }
        }
        print("Encoded \(total) tracks as \(format.rawValue.uppercased()), each checked against the rip.")
    }
}

extension AudioFormat: ExpressibleByArgument {}
