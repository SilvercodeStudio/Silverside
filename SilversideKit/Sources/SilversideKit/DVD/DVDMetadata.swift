import Foundation

/// Editable names alongside an unchanged release snapshot and the disc's source
/// boundaries. A MusicBrainz medium is not a DVD program or a CD TOC.
public struct DVDMetadata: Codable, Sendable {
    public var version = 1
    public var fingerprint: String
    public var album: String?
    public var albumArtist: String?
    public var date: String?
    public var release: MusicBrainzRelease?
    public var programs: [Program]

    public struct Reference: Codable, Equatable, Sendable {
        public var medium: Int
        public var position: Int
        public init(medium: Int, position: Int) {
            self.medium = medium
            self.position = position
        }
    }

    public struct Track: Codable, Sendable, Identifiable {
        public var id: Int { source.number }
        public var source: DVDTrack
        public var title: String?
        public var artist: String?
        public var reference: Reference?
    }

    public struct Program: Codable, Sendable {
        public var id: String
        public var name: String?
        public var tracks: [Track]
    }

    public init(inventory: DVDInventory) {
        fingerprint = inventory.fingerprint
        programs = inventory.presentations.map {
            Program(id: $0.id, tracks: $0.tracks.map { Track(source: $0) })
        }
    }

    public var albumName: String { album ?? release?.title ?? "" }
    public var artistName: String { albumArtist ?? release?.artist ?? "" }

    public static func releaseID(_ input: String) throws -> String {
        if let uuid = UUID(uuidString: input) { return uuid.uuidString.lowercased() }
        if let url = URLComponents(string: input), url.scheme == "https", url.host == "musicbrainz.org",
            url.user == nil, url.password == nil, url.port == nil
        {
            let parts = url.path.split(separator: "/")
            if parts.count == 2, parts[0] == "release", let uuid = UUID(uuidString: String(parts[1])) {
                return uuid.uuidString.lowercased()
            }
        }
        throw DVDError("Use a MusicBrainz release UUID or https://musicbrainz.org/release/UUID URL.")
    }

    public mutating func select(_ candidate: MusicBrainzRelease) throws {
        _ = try Self.releaseID(candidate.id)
        guard release?.id == candidate.id || programs.allSatisfy({ $0.tracks.allSatisfy { $0.reference == nil } })
        else { throw DVDError("Clear the existing release mappings before selecting another release.") }
        var edited = self
        edited.release = candidate
        try edited.validate()
        self = edited
    }

    public mutating func clearRelease() {
        release = nil
        for program in programs.indices {
            for track in programs[program].tracks.indices { programs[program].tracks[track].reference = nil }
        }
    }

    /// Each key is a source track number; each value is a position on the selected
    /// MusicBrainz medium. Repeated positions are explicit chapter-to-work mappings.
    public mutating func map(program id: String, medium: Int, assignments: [Int: Int]) throws {
        guard let index = programs.firstIndex(where: { $0.id == id }), !assignments.isEmpty else {
            throw DVDError("Select an existing DVD program and at least one track mapping.")
        }
        var edited = self
        for (number, position) in assignments {
            guard let track = edited.programs[index].tracks.firstIndex(where: { $0.source.number == number }) else {
                throw DVDError("Program \(id) has no source track \(number).")
            }
            let reference = Reference(medium: medium, position: position)
            _ = try recording(reference)
            edited.programs[index].tracks[track].reference = reference
        }
        try edited.validate()
        self = edited
    }

    /// UTF-8, one title per line, optionally followed by TAB and artist. Requires
    /// an exact count, including short or unidentified source tracks. Manual bulk
    /// replacement clears recording references rather than retaining unrelated IDs.
    public mutating func importTitles(_ text: String, program id: String) throws {
        guard let index = programs.firstIndex(where: { $0.id == id }) else { throw DVDError("Unknown program \(id).") }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count == programs[index].tracks.count else {
            throw DVDError(
                "Expected \(programs[index].tracks.count) lines, including every source track; got \(lines.count).")
        }
        var edited = self
        for (offset, line) in lines.enumerated() {
            let fields = line.components(separatedBy: "\t")
            guard fields.count <= 2, !fields[0].trimmingCharacters(in: .whitespaces).isEmpty else {
                throw DVDError("Line \(offset + 1) needs a title and optionally one tab-separated artist.")
            }
            edited.programs[index].tracks[offset].title = fields[0]
            edited.programs[index].tracks[offset].artist = fields.count == 2 && !fields[1].isEmpty ? fields[1] : nil
            edited.programs[index].tracks[offset].reference = nil
        }
        try edited.validate()
        self = edited
    }

    /// Empty values remove overrides and reveal the imported value again.
    public mutating func set(_ assignment: String, program id: String? = nil) throws {
        let parts = assignment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw DVDError("An edit must be field=value.") }
        let key = String(parts[0])
        let value = parts[1].isEmpty ? nil : String(parts[1])
        try Self.checkText(value)
        switch key {
        case "album": album = value
        case "albumArtist": albumArtist = value
        case "date": date = value
        default:
            guard let index = programs.firstIndex(where: { $0.id == id }) else {
                throw DVDError("Program and track edits require --title SET:TITLE.")
            }
            if key == "program" {
                programs[index].name = value
                return
            }
            let fields = key.split(separator: ".")
            guard fields.count == 2, fields[0].hasPrefix("track"),
                let number = Int(fields[0].dropFirst(5)),
                let track = programs[index].tracks.firstIndex(where: { $0.source.number == number })
            else { throw DVDError("Use album, albumArtist, date, program, trackN.title or trackN.artist.") }
            switch fields[1] {
            case "title": programs[index].tracks[track].title = value
            case "artist": programs[index].tracks[track].artist = value
            default: throw DVDError("Use trackN.title or trackN.artist.")
            }
        }
    }

    public func recording(_ reference: Reference) throws -> MusicBrainzRelease.Track {
        guard let release,
            let medium = release.media.first(where: { $0.position == reference.medium }),
            let track = medium.tracks.first(where: { $0.position == reference.position })
        else { throw DVDError("The saved release has no medium \(reference.medium), track \(reference.position).") }
        return track
    }

    public func names(_ track: Track) throws -> (title: String, artist: String) {
        let original = try track.reference.map(recording)
        let artist = original?.artist ?? ""
        return (track.title ?? original?.title ?? "", track.artist ?? (artist.isEmpty ? artistName : artist))
    }

    public func validate(inventory: DVDInventory? = nil, selected: [String] = []) throws {
        guard version == 1, !fingerprint.isEmpty,
            Set(programs.map(\.id)).count == programs.count
        else { throw DVDError("Unsupported or malformed DVD metadata document.") }
        if let inventory {
            guard fingerprint == inventory.fingerprint,
                programs.count == inventory.presentations.count,
                programs.allSatisfy({ program in
                    inventory.presentations.contains {
                        $0.id == program.id && $0.tracks == program.tracks.map(\.source)
                    }
                })
            else { throw DVDError("Metadata belongs to a different disc or its source track boundaries have changed.") }
        }
        guard Set(selected).isSubset(of: Set(programs.map(\.id))) else {
            throw DVDError("Missing selected program metadata.")
        }
        for text in [album, albumArtist, date, albumName, artistName, release?.date] { try Self.checkText(text) }
        if !selected.isEmpty, albumName.trimmingCharacters(in: .whitespaces).isEmpty {
            throw DVDError("Name the album before ripping with metadata.")
        }
        for program in programs {
            try Self.checkText(program.name)
            guard Set(program.tracks.map { $0.source.number }).count == program.tracks.count else {
                throw DVDError("Duplicate source track in program \(program.id).")
            }
            for track in program.tracks {
                if let reference = track.reference { _ = try recording(reference) }
                let resolved = try names(track)
                for text in [track.title, track.artist, resolved.title, resolved.artist] { try Self.checkText(text) }
                if selected.contains(program.id),
                    resolved.title.trimmingCharacters(in: .whitespaces).isEmpty
                        || resolved.artist.trimmingCharacters(in: .whitespaces).isEmpty
                {
                    throw DVDError("Name the title and artist of program \(program.id), track \(track.source.number).")
                }
            }
        }
    }

    static func checkText(_ text: String?) throws {
        guard let text else { return }
        guard text.utf8.count <= 8192, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw DVDError("Metadata fields must be single-line text of at most 8192 UTF-8 bytes.")
        }
    }

    func entry(program id: String, track number: Int) throws -> (Program, Track) {
        guard let program = programs.first(where: { $0.id == id }),
            let track = program.tracks.first(where: { $0.source.number == number })
        else { throw DVDError("Missing metadata for \(id), track \(number).") }
        return (program, track)
    }

    public func filename(program: String, track: Int) throws -> String {
        let (_, entry) = try entry(program: program, track: track)
        let title = try names(entry).title
        return NameTemplate.safeComponent(String(format: "%02d - %@", track, title)) + ".flac"
    }

    public func comments(program id: String, track number: Int) throws -> [(key: String, value: String)] {
        let (program, track) = try entry(program: id, track: number)
        let names = try names(track)
        var values = [
            ("TITLE", names.title), ("ARTIST", names.artist), ("ALBUM", albumName), ("ALBUMARTIST", artistName),
            ("TRACKNUMBER", String(number)), ("TRACKTOTAL", String(program.tracks.count)),
            ("MEDIA", "DVD-Audio"), ("DVD_PROGRAM", id), ("DVD_FINGERPRINT", fingerprint),
        ]
        if let date = date ?? release?.date { values.append(("DATE", date)) }
        if let name = program.name { values.append(("DISCSUBTITLE", name)) }
        if let reference = track.reference, let release {
            values.append(("MUSICBRAINZ_ALBUMID", release.id))
            if let id = try recording(reference).recordingID { values.append(("MUSICBRAINZ_TRACKID", id)) }
        }
        return values
    }

    public static func read(from url: URL) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try result.validate()
        return result
    }

    public func write(to url: URL, replacing: Bool = false) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: replacing ? .atomic : .withoutOverwriting)
    }
}
