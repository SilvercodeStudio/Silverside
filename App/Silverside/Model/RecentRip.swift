import Foundation
import SilversideKit

/// An earlier rip, for the sidebar and the results view: a rip in the rips folder (its
/// WAV files and `disc.json`), or one that was encoded, whose report is kept in the
/// library's album folder as "Rip Report (Disc N).json" after the WAV files are deleted.
nonisolated struct RecentRip: Identifiable, Sendable {
    /// The rip's folder, or the album folder in the library.
    var folder: URL
    /// The report file: `disc.json` in a rip folder, or the album folder's copy.
    var file: URL
    var report: RipReport
    /// The album's names as edited: the rip's own edits, with those kept for its release on top.
    var names = MetadataEdits()
    /// True when the folder has the rip's audio, so the rip can be pooled or repaired.
    var hasAudio: Bool
    /// True when the rip is only in the history: its files were moved or deleted (`RipHistory`).
    /// `folder` and `file` are where they were last seen.
    var isMissing = false
    /// True when the place where the rip was last seen cannot be reached now: the library's
    /// folder is not there, or its volume is not mounted (a NAS not mounted yet). Its files may
    /// well be there, so it is shown as offline, not as moved or deleted. Implies `isMissing`.
    var isOffline = false
    /// True when another rip of the disc is at the place where this one was last seen: the disc
    /// was ripped again into the same folder, or encoded again into the same album. Implies
    /// `isMissing`.
    var isReplaced = false
    /// The rip's key in the history (`RipHistory.key`): its disc, and when it was ripped and
    /// repaired. Not its report's place: a disc ripped again into the same folder leaves the
    /// earlier rip in the history at that place, and a rip keeps its key when its album moves.
    let id: String

    /// A rip in the rips folder.
    init(folder: URL, report: RipReport) {
        self.folder = folder
        file = folder.appending(path: "disc.json")
        self.report = report
        hasAudio = true
        id = RipHistory.key(of: report, file: file)
    }

    /// A report kept in the library, next to the encoded files.
    init(libraryReport file: URL, report: RipReport) {
        folder = file.deletingLastPathComponent()
        self.file = file
        self.report = report
        hasAudio = false
        id = RipHistory.key(of: report, file: file)
    }

    /// A rip as the history has it: a rip in the rips folder, a report kept in the library next
    /// to the encoded files, or where its report was last seen, there or not. Its names are its
    /// own edits, with those kept for its release on top.
    init(
        entry: RipHistory.Entry, isMissing: Bool, isOffline: Bool = false, isReplaced: Bool = false,
        store: ReleaseEditsStore
    ) {
        file = entry.url
        folder = entry.url.deletingLastPathComponent()
        report = entry.report
        hasAudio = entry.hasAudio
        self.isMissing = isMissing || isOffline || isReplaced
        self.isOffline = isOffline
        self.isReplaced = isReplaced
        id = RipHistory.key(of: entry.report, file: entry.url)
        if let release = report.release {
            names =
                MetadataEdits.current(
                    own: entry.edits ?? MetadataEdits(), release: release, rip: RipIdentity(report: report),
                    store: store
                ).albumLevel
        }
    }

    /// The rip's key in the history.
    var historyKey: String { id }

    /// The album, with the disc's number in a set: "Europe '72 (Disc 2)".
    var title: String {
        guard let release = report.release else { return folder.lastPathComponent }
        let album = names.album ?? release.title
        guard release.media.count > 1, let position = report.discPosition else { return album }
        return "\(album) (Disc \(position))"
    }
    var artist: String { names.albumArtist ?? report.release?.artist ?? "" }
    var isVerified: Bool { report.isVerified }
    /// Where the rip is: its folder with the audio, or the library with its encoded files.
    var location: String {
        isOffline
            ? "Offline"
            : isReplaced ? "Replaced" : isMissing ? "Moved or deleted" : hasAudio ? "Rips folder" : "Library"
    }
    var driveName: String { "\(report.drive.vendor) \(report.drive.product)" }
    /// What the disc is: "CD", "Enhanced CD", "HDCD, decoded".
    var medium: String { DiscLogo.medium(of: report) ?? "" }
    var date: Date { report.date }
    /// The user's notes on the rip, or "".
    var notes: String { report.notes ?? "" }

    /// A rip that a database did not have, or that is not verified, with its audio to check
    /// again: its WAV files, or the album's lossless files, not an HDCD decode.
    var canCheckAgain: Bool {
        guard report.mayCheckAgain else { return false }
        return hasAudio
            || (report.encoding?.format.isLossless == true && report.encoding?.hdcdDecoded != true
                && report.encoding?.dtsDecoded == nil)
    }

    /// The tracks that AccurateRip or CTDB proves.
    var verifiedCount: Int { Self.verifiedCount(of: report) }

    static func verifiedCount(of report: RipReport) -> Int {
        let wholeDisc = report.ctdb.status == .verified || report.ctdb.status == .repaired
        return report.tracks.filter {
            wholeDisc || $0.accurateRip == .accurate || $0.accurateRip == .otherPressings
                || ($0.ctdbConfidence ?? 0) > 0
        }.count
    }

    /// The artist, when the rip was made (two rips of a disc look alike otherwise), and what
    /// is not verified. The drive is in `details`, for a tooltip: its names wrap badly.
    var subtitle: String {
        var parts = [String]()
        if !artist.isEmpty { parts.append(artist) }
        parts.append(report.date.formatted(date: .abbreviated, time: .omitted))
        let unverified = report.tracks.count - verifiedCount
        if unverified > 0 { parts.append("\(unverified) unverified" + (report.accepted != nil ? ", accepted" : "")) }
        if isOffline {
            parts.append("offline")
        } else if isReplaced {
            parts.append("replaced")
        } else if isMissing {
            parts.append("moved or deleted")
        } else if !hasAudio {
            parts.append("encoded")
        }
        return parts.joined(separator: " · ")
    }

    var details: String {
        "Ripped \(report.date.formatted(date: .abbreviated, time: .shortened)) on \(report.drive.vendor) \(report.drive.product), read offset \(report.drive.readOffset.signedDescription)."
            + (hasAudio ? "" : " Encoded into the library; the rip's WAV files were deleted, and this is its report.")
    }

    /// The rips found, kept in the history (`RipHistory`), and the history's other rips: those
    /// elsewhere (a library folder used before), and those whose files are gone, as missing.
    /// An album report that has not changed since the history kept it is not read again, so a
    /// library on a NAS costs only its folder listings.
    static func scan(rips: URL, library: URL, history: RipHistory) -> Found {
        let entries = history.entries()
        let found = scan(rips: rips, library: library, history: history, known: RipHistory.byFile(entries))
        var keys = Set<String>()
        var present = [RipHistory.Entry]()
        for entry in found {
            keys.insert((try? history.record(entry)) ?? entry.key)
            present.append(entry)
        }
        var missing = [RipHistory.Entry]()
        var offline = [RipHistory.Entry]()
        var places = Places(rips: rips, library: library)
        for (key, entry) in entries where !keys.contains(key) {
            if places.isOffline(entry.url) {
                offline.append(entry)
                continue
            }
            // There only if the report at that place is still this rip's: a later rip of the disc
            // can have taken its folder. A report that changed is read again, for its new names.
            guard let now = history.current(entry, key: key) else {
                missing.append(entry)
                continue
            }
            if now != entry { _ = try? history.record(now) }
            present.append(now)
        }
        return Found(present: present, offline: offline, missing: missing)
    }

    /// The history's rips, in three lists, the newest first: those found, those whose place
    /// cannot be reached now, and those moved, deleted, or replaced (`isReplaced`: a rip found
    /// is at their place).
    struct Found {
        var present: [RecentRip]
        var offline: [RecentRip]
        var missing: [RecentRip]

        init(present: [RipHistory.Entry], offline: [RipHistory.Entry], missing: [RipHistory.Entry]) {
            let store = ReleaseEditsStore()
            func rips(_ entries: [RipHistory.Entry], missing: Bool, offline: Bool) -> [RecentRip] {
                entries.map { RecentRip(entry: $0, isMissing: missing, isOffline: offline, store: store) }
                    .sorted { $0.report.date > $1.report.date }
            }
            self.present = rips(present, missing: false, offline: false)
            self.offline = rips(offline, missing: true, offline: true)
            let places = Set(present.map { $0.url.standardizedFileURL.path })
            self.missing = missing.map {
                RecentRip(
                    entry: $0, isMissing: true, isReplaced: places.contains($0.url.standardizedFileURL.path),
                    store: store)
            }
            .sorted { $0.report.date > $1.report.date }
        }
    }

    /// Which places cannot be reached now: the rips folder or the library when its folder is not
    /// there, and a volume under /Volumes that is not mounted. Each is looked at once.
    struct Places {
        private let roots: [String]
        private var reachable: [String: Bool] = [:]

        init(rips: URL, library: URL) {
            roots = [rips, library].map { $0.standardizedFileURL.path }
        }

        mutating func isOffline(_ file: URL) -> Bool {
            let path = file.standardizedFileURL.path
            if let root = roots.first(where: { path.hasPrefix($0 + "/") }), !isReachable(root, volume: false) {
                return true
            }
            let parts = path.split(separator: "/")
            guard parts.count > 2, parts[0] == "Volumes" else { return false }
            return !isReachable("/Volumes/\(parts[1])", volume: true)
        }

        /// A folder that exists, or, with `volume`, a folder that is a mounted volume: an empty
        /// folder can stay at a NAS's mount point after it is gone.
        private mutating func isReachable(_ path: String, volume: Bool) -> Bool {
            if let known = reachable[path] { return known }
            let url = URL(filePath: path, directoryHint: .isDirectory)
            let found =
                volume
                ? (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
                : FileManager.default.fileExists(atPath: path)
            reachable[path] = found
            return found
        }
    }

    /// The history's rips without a look at their files, for the moment before a scan ends.
    /// A rip in the rips folder or the library counts as there, one whose place cannot be
    /// reached as offline, and one elsewhere as missing.
    static func remembered(rips: URL, library: URL, history: RipHistory) -> Found {
        let folders = [rips, library].map { $0.standardizedFileURL.path + "/" }
        var places = Places(rips: rips, library: library)
        var present = [RipHistory.Entry]()
        var offline = [RipHistory.Entry]()
        var missing = [RipHistory.Entry]()
        for entry in history.entries().values {
            if places.isOffline(entry.url) {
                offline.append(entry)
            } else if folders.contains(where: { entry.file.hasPrefix($0) }) {
                present.append(entry)
            } else {
                missing.append(entry)
            }
        }
        return Found(present: present, offline: offline, missing: missing)
    }

    /// The rips in the rips folder, and the reports in the library's album folders. A rip that
    /// is in both places (kept after encoding) is listed once.
    private static func scan(rips: URL, library: URL, history: RipHistory, known: [String: RipHistory.Entry])
        -> [RipHistory.Entry]
    {
        var found = scanRips(rips, history: history)
        // A repair's report keeps the rip's time; its own time tells it apart.
        func identity(_ entry: RipHistory.Entry) -> String {
            let report = entry.report
            return "\(report.toc) \(report.date.timeIntervalSince1970) \(report.repaired?.timeIntervalSince1970 ?? 0)"
        }
        var seen = Set(found.map(identity))
        for entry in scanLibrary(library, skipping: rips, history: history, known: known) {
            let key = identity(entry)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            found.append(entry)
        }
        return found
    }

    private static func scanRips(_ folder: URL, history: RipHistory) -> [RipHistory.Entry] {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        else { return [] }
        return entries.compactMap { entry in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let json = entry.appending(path: "disc.json")
            guard manager.fileExists(atPath: json.path) else { return nil }
            return history.entry(forReportAt: json, hasAudio: true)
        }
    }

    /// "Rip Report*.json" files up to four levels down (the album folder template is
    /// usually artist/album), leaving the rips folder alone if it is inside the library.
    private static func scanLibrary(
        _ library: URL, skipping rips: URL, history: RipHistory, known: [String: RipHistory.Entry]
    ) -> [RipHistory.Entry] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: library, includingPropertiesForKeys: [.isDirectoryKey] + RipHistory.Stamp.resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        let skipped = rips.standardizedFileURL.path
        var found = [RipHistory.Entry]()
        while let entry = enumerator.nextObject() as? URL {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                if enumerator.level >= 4 || entry.standardizedFileURL.path == skipped { enumerator.skipDescendants() }
                continue
            }
            // A decoded copy beside an album ("… (HDCD)") is not a rip of its own.
            guard RipReport.Encoding.isAlbumReport(entry),
                let rip = history.entry(forReportAt: entry, hasAudio: false, known: known),
                rip.report.encoding?.albumSuffix == nil
            else { continue }
            found.append(rip)
        }
        return found
    }
}
