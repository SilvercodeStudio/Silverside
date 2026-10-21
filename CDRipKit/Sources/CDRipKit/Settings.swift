import Foundation

/// The artwork to save from the Cover Art Archive.
public enum ArtworkChoice: String, Codable, CaseIterable, Sendable {
    /// The front cover, as cover.jpg.
    case front
    /// The front cover, and the other images in Artwork/.
    case all
    /// No artwork.
    case none
}

/// The user's settings, for `cdrip` and the app: one JSON file in
/// `~/Library/Application Support/CDRip/settings.json`. Every key may be left out, and then
/// has its default, so a file from an older version still reads. Options on the command
/// line override the file.
public struct Settings: Codable, Equatable, Sendable {
    /// The music library, for encoded files.
    public var library = "~/Music/CDRip Library"
    /// Where rips go when `cdrip rip -o` is not given: a folder of their own, out of the
    /// library (music apps would import the WAV files) and out of temporary folders (a rip
    /// is kept for repairs and later encoding).
    public var rips = "~/Music/CDRip Rips"
    public var format = AudioFormat.flac
    /// The album folder in the library (see `NameTemplate`).
    public var folderTemplate = NameTemplate.libraryFolder.pattern
    /// Each track's file name in the library, with no extension.
    public var trackTemplate = NameTemplate.libraryTrack.pattern
    /// Each rip's folder, under `rips`.
    public var ripFolderTemplate = NameTemplate.folder.pattern
    /// Add "[Venue, M-D-YY]" to titles, and take dates from disc titles, for live shows.
    public var liveShowStyle = true
    /// Turn typographic punctuation into ASCII in names and tags ("Walkin’" becomes "Walkin'").
    public var plainPunctuation = false
    public var artwork = ArtworkChoice.front
    /// Ask the drive for C2 error flags.
    public var readC2 = true
    /// Encode each disc into the library after `cdrip rip`, in `format`.
    public var encodeAfterRip = false
    /// Keep the rip's WAV files after `cdrip rip --encode`. If false, a rip whose tracks are
    /// all verified and encoded is deleted; its report goes into the album folder.
    public var keepRipAfterEncoding = false
    /// Eject the disc after `cdrip rip`, if every track is verified.
    public var ejectAfterRip = false
    public var aac = AACOptions()
    public var mp3 = MP3Options()

    public init() {}

    /// The settings file. The environment variable `CDRIP_SETTINGS` can name another one.
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["CDRIP_SETTINGS"], !path.isEmpty {
            return URL(filePath: path)
        }
        return DriveProfileStore.defaultDirectory.appending(path: "settings.json")
    }

    /// The settings in the file, or the defaults if there is no file.
    public static func load(from url: URL = defaultURL) throws -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
        do {
            return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
        } catch {
            throw SettingsError.unreadable(url, String(describing: error))
        }
    }

    /// Saves the settings. Keys in the file that this version of CDRip does not know (from
    /// a newer version of the CLI or the app) are kept.
    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        let merged = JSONMerge.overlay(try Self.object(self), on: file)
        try JSONSerialization.data(
            withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        .write(to: url, options: .atomic)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The library folder, with "~" made into the home folder.
    public var libraryURL: URL { Self.expand(library) }

    /// The folder for rips: the `rips` setting, or the current folder if it is empty.
    public var ripsURL: URL { rips.isEmpty ? URL.currentDirectory() : Self.expand(rips) }

    /// A path with "~" made into the home folder.
    public static func expand(_ path: String) -> URL {
        URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }

    /// The settings with one key changed, such as "format" or "aac.bitRate". The value is
    /// JSON if it reads as JSON (a number, true, false), and text if not. Throws if the
    /// key does not exist, or the value has the wrong type.
    public func setting(_ key: String, to value: String) throws -> Settings {
        let parsed: Any =
            (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)) ?? value
        return try changing(key) { $0 = parsed }
    }

    /// The settings with one key back to its default.
    public func resetting(_ key: String) throws -> Settings {
        let defaults = try Self.object(Settings())
        let path = key.split(separator: ".").map(String.init)
        var value: Any? = defaults
        for part in path { value = (value as? [String: Any])?[part] }
        guard let value else { throw SettingsError.unknownKey(key) }
        return try changing(key) { $0 = value }
    }

    /// The value of a key, as JSON text. An empty key gives every setting.
    public func value(of key: String) throws -> String {
        var value: Any? = try Self.object(self)
        for part in key.split(separator: ".") { value = (value as? [String: Any])?[String(part)] }
        guard let value else { throw SettingsError.unknownKey(key) }
        let data = try JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private func changing(_ key: String, _ change: (inout Any) -> Void) throws -> Settings {
        var object = try Self.object(self)
        let path = key.split(separator: ".").map(String.init)
        func update(_ dictionary: inout [String: Any], _ path: ArraySlice<String>) throws {
            guard let first = path.first, var current = dictionary[first] else { throw SettingsError.unknownKey(key) }
            if path.count == 1 {
                change(&current)
            } else {
                guard var nested = current as? [String: Any] else { throw SettingsError.unknownKey(key) }
                try update(&nested, path.dropFirst())
                current = nested
            }
            dictionary[first] = current
        }
        try update(&object, path[...])
        do {
            return try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: object))
        } catch {
            throw SettingsError.wrongValue(key)
        }
    }

    private static func object(_ settings: Settings) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: encoder.encode(settings)) as! [String: Any]
    }

    // Every key may be missing: it then has its default.
    public init(from decoder: any Decoder) throws {
        let defaults = Settings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        library = try value(.library, defaults.library)
        rips = try value(.rips, defaults.rips)
        format = try value(.format, defaults.format)
        folderTemplate = try value(.folderTemplate, defaults.folderTemplate)
        trackTemplate = try value(.trackTemplate, defaults.trackTemplate)
        ripFolderTemplate = try value(.ripFolderTemplate, defaults.ripFolderTemplate)
        liveShowStyle = try value(.liveShowStyle, defaults.liveShowStyle)
        plainPunctuation = try value(.plainPunctuation, defaults.plainPunctuation)
        artwork = try value(.artwork, defaults.artwork)
        readC2 = try value(.readC2, defaults.readC2)
        encodeAfterRip = try value(.encodeAfterRip, defaults.encodeAfterRip)
        keepRipAfterEncoding = try value(.keepRipAfterEncoding, defaults.keepRipAfterEncoding)
        ejectAfterRip = try value(.ejectAfterRip, defaults.ejectAfterRip)
        aac = try value(.aac, defaults.aac)
        mp3 = try value(.mp3, defaults.mp3)
    }
}

public enum SettingsError: Error, Equatable, CustomStringConvertible {
    case unreadable(URL, String)
    case unknownKey(String)
    case wrongValue(String)

    public var description: String {
        switch self {
        case .unreadable(let url, let reason): "Cannot read the settings in \(url.path): \(reason)"
        case .unknownKey(let key): "There is no setting \"\(key)\". See cdrip config show."
        case .wrongValue(let key): "That is not a valid value for \"\(key)\"."
        }
    }
}

/// Merges JSON objects, so that a file written by a newer version keeps its keys when an
/// older version saves it.
enum JSONMerge {
    /// `new` on top of `base`: every key of `new` wins, objects in both are merged, and
    /// keys only in `base` stay.
    static func overlay(_ new: [String: Any], on base: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in new {
            if let object = value as? [String: Any], let old = base[key] as? [String: Any] {
                result[key] = overlay(object, on: old)
            } else {
                result[key] = value
            }
        }
        return result
    }
}
