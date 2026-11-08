import ArgumentParser
import Foundation
import SilversideKit

struct DVDMetadataCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metadata", abstract: "Select and edit saved DVD-Audio metadata without accessing a drive.",
        discussion: """
            Start from dvd info --json using --inventory FILE --output FILE. Reopen with --input FILE.
            Import a MusicBrainz release with --release URL-or-ID; this does not assign its tracks.
            Assign tracks explicitly with --title SET:TITLE --medium N --map 1=13,2=14,... .
            Use --set album=..., --set albumArtist=..., --set program=..., or --set track1.title=... .
            --titles FILE imports one title per line, optionally TAB artist, for every track in --title.
            Edits update --input atomically, or write a new --output file. Without edits, only displays names.
            Names and IDs remain separate from the source boundaries. No tracks are skipped or joined.
            """)
    @Option(help: "Saved dvd info --json inventory, used to create a new document.") var inventory: String?
    @Option(name: .shortAndLong, help: "Existing metadata document to display or edit.") var input: String?
    @Option(name: .shortAndLong, help: "New metadata file; must not exist.") var output: String?
    @Option(help: "MusicBrainz release URL or UUID; fetched through the shared cache and rate limiter.")
    var release: String?
    @Flag(help: "Clear the selected release and every mapping; keep explicit manual overrides.") var clearRelease =
        false
    @Option(help: "DVD program to edit, such as 1:1.") var title: String?
    @Option(help: "MusicBrainz medium position; required with --map.") var medium: Int?
    @Option(name: .customLong("map"), help: "Comma-separated source-track=MusicBrainz-position assignments.")
    var mapping: String?
    @Option(help: "UTF-8 titles, one per source track, optionally TAB artist. Replaces this program's mappings.")
    var titles: String?
    @Option(name: .customLong("set"), help: "field=value edit; repeat for multiple fields. Empty removes an override.")
    var edits: [String] = []

    func validate() throws {
        guard (inventory == nil) != (input == nil) else { throw ValidationError("Use either --inventory or --input.") }
        guard inventory == nil || output != nil else { throw ValidationError("Creating metadata requires --output.") }
        guard (mapping == nil) == (medium == nil), mapping == nil || title != nil else {
            throw ValidationError("--map requires --title and --medium together.")
        }
        guard titles == nil || (title != nil && mapping == nil) else {
            throw ValidationError("--titles requires --title and cannot be combined with --map.")
        }
        if let release { _ = try DVDMetadata.releaseID(release) }
    }

    func run() async throws {
        var document: DVDMetadata
        if let inventory {
            let data = try Data(contentsOf: URL(fileURLWithPath: inventory))
            let source = try JSONDecoder().decode(DVDInventory.self, from: data)
            document = DVDMetadata(inventory: source)
            try document.validate(inventory: source)
        } else {
            document = try DVDMetadata.read(from: URL(fileURLWithPath: input!))
        }
        if let title, !document.programs.contains(where: { $0.id == title }) {
            throw CommandError("No DVD program \(title) in this document.")
        }
        if clearRelease { document.clearRelease() }
        if let release {
            let id = try DVDMetadata.releaseID(release)
            guard let candidate = try await MusicBrainzClient().release(id: id) else {
                throw CommandError("MusicBrainz has no release \(id).")
            }
            try document.select(candidate)
        }
        if let mapping, let title, let medium {
            var assignments = [Int: Int]()
            for item in mapping.split(separator: ",", omittingEmptySubsequences: false) {
                let pair = item.split(separator: "=", omittingEmptySubsequences: false)
                guard pair.count == 2, let source = Int(pair[0]), let target = Int(pair[1]),
                    source > 0, target > 0, assignments[source] == nil
                else { throw CommandError("Use unique source-track=MusicBrainz-position pairs, such as 1=13,2=14.") }
                assignments[source] = target
            }
            try document.map(program: title, medium: medium, assignments: assignments)
        }
        if let titles, let title {
            try document.importTitles(String(contentsOfFile: titles, encoding: .utf8), program: title)
        }
        for edit in edits { try document.set(edit, program: title) }
        try document.validate()
        if let output {
            try document.write(to: URL(fileURLWithPath: output))
            print("Saved \(output)")
        } else if release != nil || clearRelease || mapping != nil || titles != nil || !edits.isEmpty {
            try document.write(to: URL(fileURLWithPath: input!), replacing: true)
            print("Updated \(input!)")
        }
        try display(document)
    }

    private func display(_ document: DVDMetadata) throws {
        print("\(document.artistName) — \(document.albumName)")
        print("Disc fingerprint: \(document.fingerprint)")
        for program in document.programs where title == nil || program.id == title {
            print("Program \(program.id)\(program.name.map { " — " + $0 } ?? "")")
            for track in program.tracks {
                let names = try document.names(track)
                var mapping = "manual/unmapped"
                if let reference = track.reference {
                    mapping = "MB \(reference.medium):\(reference.position)"
                    if let length = try document.recording(reference).length {
                        let delta = Double(track.source.durationPTS) / 90000 - Double(length) / 1000
                        mapping += String(format: "; duration difference %+.2fs", delta)
                    }
                }
                print(
                    String(format: "  %02d  %.3fs  ", track.source.number, Double(track.source.durationPTS) / 90000)
                        + "\(names.title.isEmpty ? "[needs title]" : names.title) — \(names.artist) [\(mapping)]")
            }
        }
        if let release = document.release {
            print("Release candidate: \(release.id) (tracks are assigned only by --map)")
            for medium in release.media {
                print("  Medium \(medium.position): \(medium.format ?? "unknown format")")
                for track in medium.tracks {
                    print("    \(track.position): \(track.title) — \(track.artist)")
                }
            }
        }
    }
}
