import CryptoKit
import Foundation

/// A log of every rip, kept apart from the rips folder and the library, so that a rip stays in
/// the history after its files are deleted or moved, to a NAS for example. Each rip is a file in
/// the history folder with its whole report and where its report file was last seen. The app
/// records each rip it finds when it looks through the rips folder and the library; the
/// command line records its own rips and encodings.
public struct RipHistory: Sendable {
    /// One rip: its report, and its report file, as it was last seen.
    public struct Entry: Codable, Equatable, Sendable {
        public var report: RipReport
        /// The report file: a rip's `disc.json`, or an album folder's `Rip Report*.json`.
        public var file: String
        /// True if the report is in a rip's folder with its audio.
        public var hasAudio: Bool

        public var url: URL { URL(filePath: file) }
    }

    public let directory: URL

    /// The history folder is "History" beside the settings file, so that a scratch settings
    /// file (`SILVERSIDE_SETTINGS`) keeps a scratch history.
    public init(
        directory: URL = Settings.defaultURL.deletingLastPathComponent().appending(
            path: "History", directoryHint: .isDirectory)
    ) {
        self.directory = directory
    }

    /// The rip's key: its disc and the time of the rip, as the app tells rips apart, and for a
    /// repair's folder, whose report keeps the rip's time, the repair's time
    /// (`RipReport.repaired`). A repair from before 0.9 has no such time: its "… repaired"
    /// folder name tells it apart, so it is told apart only while it keeps that name.
    public static func key(of report: RipReport, file: URL) -> String {
        let repaired =
            report.repaired.map { " repaired \($0.timeIntervalSince1970)" }
            ?? (file.deletingLastPathComponent().lastPathComponent.hasSuffix(" repaired") ? " repaired" : "")
        let text = "\(report.toc) \(report.date.timeIntervalSince1970)\(repaired)"
        return Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Keeps the rip, or updates it if its report or its place changed. Returns its key.
    @discardableResult
    public func record(_ report: RipReport, file: URL, hasAudio: Bool) throws -> String {
        let key = Self.key(of: report, file: file)
        let entry = Entry(report: report, file: file.standardizedFileURL.path, hasAudio: hasAudio)
        let url = directory.appending(path: key + ".json")
        let data = try Self.encoder.encode(entry)
        guard (try? Data(contentsOf: url)) != data else { return key }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return key
    }

    /// Keeps the report in `file`, if it can be read. A rip folder's `disc.json` has its audio.
    public func recordReport(at file: URL) {
        guard let report = try? RipReport.read(from: file) else { return }
        _ = try? record(report, file: file, hasAudio: file.lastPathComponent == "disc.json")
    }

    /// Keeps each album report (`Rip Report*.json`) in an album folder.
    public func recordAlbum(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("Rip Report") && name.hasSuffix(".json") {
            recordReport(at: folder.appending(path: name))
        }
    }

    /// Every rip kept, by key.
    public func entries() -> [String: Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var entries = [String: Entry]()
        for name in names where name.hasSuffix(".json") {
            let url = directory.appending(path: name)
            if let data = try? Data(contentsOf: url), let entry = try? Self.decoder.decode(Entry.self, from: data) {
                entries[String(name.dropLast(5))] = entry
            }
        }
        return entries
    }

    /// True if the rip's report is still where it was last seen: a report there of another rip
    /// (a later rip of the disc that took its folder) does not count.
    public static func isThere(_ entry: Entry, key: String) -> Bool {
        (try? RipReport.read(from: entry.url)).map { Self.key(of: $0, file: entry.url) } == key
    }

    /// Takes a rip out of the history.
    public func forget(key: String) throws {
        try FileManager.default.removeItem(at: directory.appending(path: key + ".json"))
    }

    /// Looks through `folder`, up to six levels down, for the report files of the rips with
    /// `keys`, and keeps each one found in its new place. Returns how many were found.
    @discardableResult
    public func locate(_ keys: Set<String>, in folder: URL) -> Int {
        guard
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return 0 }
        var found = Set<String>()
        while let entry = enumerator.nextObject() as? URL, found.count < keys.count {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if enumerator.level >= 6 { enumerator.skipDescendants() }
                continue
            }
            let name = entry.lastPathComponent
            guard name == "disc.json" || (name.hasPrefix("Rip Report") && name.hasSuffix(".json")),
                let report = try? RipReport.read(from: entry)
            else { continue }
            let key = Self.key(of: report, file: entry)
            guard keys.contains(key), !found.contains(key),
                (try? record(report, file: entry, hasAudio: name == "disc.json")) != nil
            else { continue }
            found.insert(key)
        }
        return found.count
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
