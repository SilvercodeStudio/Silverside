import Foundation

/// Apple's Music app: encoded files go into its library, where they are, or copied into
/// Music's own folder if its "Copy files to Music Media folder when adding to Library"
/// setting is on. Silverside asks Music by Apple Events through `osascript`, so macOS asks
/// the user once to allow it. (Music's "Automatically Add to Music" folder is not used:
/// it moves the files out of the library.) Music cannot play FLAC, so a FLAC album goes in
/// as copies (`MusicAdd`).
public enum MusicApp {
    /// Music reads every format Silverside writes but FLAC.
    public static func reads(_ format: AudioFormat) -> Bool { format != .flac }

    /// A track in Music's library.
    public struct Track: Equatable, Sendable {
        /// Music's ID for the track, which never changes.
        public var persistentID: String
        /// The file that Music plays, if it said.
        public var location: URL?
        /// The track's album, as Music has it, if it said.
        public var album: String?

        public init(persistentID: String, location: URL? = nil, album: String? = nil) {
            self.persistentID = persistentID
            self.location = location
            self.album = album
        }
    }

    /// An album to look for in Music's library, as its files' tags name it.
    public struct Album: Equatable, Sendable {
        public var title: String
        /// The album artist, or the files' artist when they have none.
        public var artist: String
        /// The disc, for an album of more than one disc; nil for any.
        public var disc: Int?
        /// The tracks that Silverside gave Music before (`RipReport.Encoding.MusicRecord`).
        public var trackIDs: [String]

        public init(title: String, artist: String, disc: Int? = nil, trackIDs: [String] = []) {
            self.title = title
            self.artist = artist
            self.disc = disc
            self.trackIDs = trackIDs
        }
    }

    /// What Music has of an album.
    public struct Found: Equatable, Sendable {
        /// Tracks of the album's artist (and disc) whose album is its title, or its title with
        /// words in brackets after it, as "Abbey Road (Remastered)".
        public var tracks: [Track] = []
        /// How many of the tracks that Silverside gave Music before it still has.
        public var addedBefore = 0

        public init(tracks: [Track] = [], addedBefore: Int = 0) {
            self.tracks = tracks
            self.addedBefore = addedBefore
        }

        public var isEmpty: Bool { tracks.isEmpty && addedBefore == 0 }

        /// The tracks whose album is the very title, without case.
        public func sameTitle(as album: Album) -> [Track] {
            tracks.filter { $0.album?.caseInsensitiveCompare(album.title) == .orderedSame }
        }

        /// True if Music has the album itself: tracks that Silverside gave it, or tracks of the
        /// very title. Tracks of an edition with more words in its title only look like it.
        public func hasAlbum(_ album: Album) -> Bool {
            addedBefore > 0 || !sameTitle(as: album).isEmpty
        }

        /// For people: "Music has 12 tracks of “Abbey Road” by The Beatles (disc 1), which
        /// Silverside added". Nil if it has none.
        public func description(of album: Album) -> String? {
            guard !isEmpty else { return nil }
            var names = Set(tracks.compactMap(\.album)).sorted()
            if names.isEmpty { names = [album.title] }
            let count = max(tracks.count, addedBefore)
            let disc = album.disc.map { " (disc \($0))" } ?? ""
            let titles = names.map { "“\($0)”" }.joined(separator: " and ")
            let artist = album.artist.isEmpty ? "" : " by \(album.artist)"
            return "Music has \(count) track\(count == 1 ? "" : "s") of \(titles)\(artist)\(disc)"
                + (addedBefore > 0 ? ", which Silverside added." : ".")
        }
    }

    /// Adds the files to Music's library, and returns the tracks that Music says it added, with
    /// the files it plays: these files, or its copies in its own folder. Empty when Music does
    /// not say. It waits for Music, which may have to start, and for the user's answer the first time.
    @discardableResult
    public static func add(_ files: [URL]) throws -> [Track] {
        guard !files.isEmpty else { return [] }
        return tracks(in: try run(addScript, files.map(\.path)))
    }

    /// The tracks of Music's library that look like the album (`Found`), and how many of the
    /// tracks that Silverside gave it before it still has. Music starts if it is not running.
    public static func find(_ album: Album) throws -> Found {
        let output = try run(findScript, [album.title, album.artist, String(album.disc ?? 0)] + album.trackIDs)
        return found(in: output)
    }

    /// The script that adds: the files come as arguments, so no path is ever read as
    /// AppleScript. Each added track gives a line, its persistent ID and its file.
    static let addScript = """
        on run argv
            set theFiles to {}
            repeat with thePath in argv
                set end of theFiles to (POSIX file (contents of thePath)) as alias
            end repeat
            -- An album on a slow disk can take Music longer than the 2 minutes it is given.
            with timeout of 600 seconds
                tell application "Music" to set added to add theFiles
            end timeout
            set theLines to {}
            try
                if class of added is not list then set added to {added}
                repeat with theTrack in added
                    tell application "Music" to set theID to persistent ID of theTrack
                    set thePath to ""
                    try
                        tell application "Music" to set theLocation to location of theTrack
                        set thePath to POSIX path of theLocation
                    end try
                    set end of theLines to theID & tab & thePath
                end repeat
            end try
            set AppleScript's text item delimiters to linefeed
            return theLines as text
        end run
        """

    /// The script that looks for an album: its title, artist, and disc (0 for any), then the
    /// IDs of tracks added before. A line for each track that looks like the album ("album",
    /// its ID, its album), and for each of those IDs that Music still has ("added", the ID).
    static let findScript = """
        on run argv
            set theTitle to item 1 of argv
            set theArtist to item 2 of argv
            set theDisc to (item 3 of argv) as integer
            set theIDs to {}
            if (count of argv) > 3 then set theIDs to items 4 thru -1 of argv
            set theLines to {}
            tell application "Music"
                if theTitle is not "" then
                    set theTracks to (every track of library playlist 1 whose album is theTitle ¬
                        or album starts with (theTitle & " (") or album starts with (theTitle & " ["))
                    repeat with theTrack in theTracks
                        set theAlbum to album of theTrack
                        set theAlbumArtist to album artist of theTrack
                        set theTrackArtist to artist of theTrack
                        set theNumber to disc number of theTrack
                        if (theArtist is "" or theAlbumArtist is theArtist or theTrackArtist is theArtist) ¬
                            and (theDisc is 0 or theNumber is theDisc or theNumber is 0) then
                            set end of theLines to "album" & tab & (persistent ID of theTrack) & tab & theAlbum
                        end if
                    end repeat
                end if
                repeat with theItem in theIDs
                    set theID to contents of theItem
                    if exists (some track of library playlist 1 whose persistent ID is theID) then
                        set end of theLines to "added" & tab & theID
                    end if
                end repeat
            end tell
            set AppleScript's text item delimiters to linefeed
            return theLines as text
        end run
        """

    /// The add script's lines as tracks.
    static func tracks(in output: String) -> [Track] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let id = parts.first, !id.isEmpty else { return nil }
            let path = parts.count > 1 ? parts[1] : ""
            return Track(persistentID: id, location: path.isEmpty ? nil : URL(filePath: path))
        }
    }

    /// The find script's lines.
    static func found(in output: String) -> Found {
        var found = Found()
        var seen = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            switch parts.first {
            case "album" where parts.count == 3 && seen.insert(parts[1]).inserted:
                found.tracks.append(Track(persistentID: parts[1], album: parts[2]))
            case "added" where parts.count >= 2:
                found.addedBefore += 1
            default: continue
            }
        }
        return found
    }

    /// Runs a script with `osascript`, and returns what it printed.
    private static func run(_ script: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            // errAEEventNotPermitted: the user said no, or has not been asked in this context.
            if message.contains("-1743") { throw MusicAppError.notAllowed }
            throw MusicAppError.failed(message)
        }
        return String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum MusicAppError: Error, Equatable, CustomStringConvertible {
    case notAllowed
    case failed(String)

    public var description: String {
        switch self {
        case .notAllowed:
            "Silverside may not control Music. Allow it in System Settings › Privacy & Security › Automation."
        case .failed(let message): "Music gave an error: \(message)"
        }
    }
}
