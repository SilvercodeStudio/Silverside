import Foundation

/// An album's files added to Apple's Music app (`MusicApp`): as they are, in the formats that
/// Music plays, and as copies in Apple Lossless or AAC for FLAC, which it does not play. The
/// copies go in a folder of their own (`Settings.musicCopies`), each album where the library has
/// it, never in the library, and never over a file that is there. When Music copies the files it
/// adds into its own folder, as its settings do by default, Silverside deletes its copies; when
/// Music plays them where they are, they stay.
public struct MusicAdd: Sendable {
    /// The format of the copies: Apple Lossless or AAC (with `aac`).
    public var format: AudioFormat
    public var aac: AACOptions
    /// The folder of the copies.
    public var copies: URL
    /// The library: an album's copies take its place there, in `copies`.
    public var library: URL
    /// How many files are copied at once.
    public var parallelTracks = DiscEncoder.defaultParallelTracks
    /// Receives a line for each step, for people to read.
    public var log: @Sendable (String) -> Void = { _ in }

    public init(settings: Settings) {
        format = settings.musicFormat == .aac ? .aac : .alac
        aac = settings.aac
        copies = settings.musicCopiesURL
        library = settings.libraryURL
    }

    /// What an add did.
    public struct Added: Sendable {
        /// The add, for the album's report (`RipReport.Encoding.saveMusic`).
        public var record: RipReport.Encoding.MusicRecord
        /// The tracks that Music added: as many as it named, else as many as the files.
        public var tracks: Int
        /// The copies made, and how many of them stay in `copies`, as Music plays them there.
        public var copies: Int
        public var keptCopies: Int
    }

    /// The files of a report's album, in the order of the tracks, and their format. An album that
    /// keeps a DTS-CD's stream cannot go, as Music plays the stream as noise.
    public static func files(of report: RipReport) throws -> (files: [URL], format: AudioFormat) {
        guard let encoding = report.encoding, !encoding.files.isEmpty else { throw MusicAddError.notEncoded }
        if report.dts == .stream, encoding.dtsDecoded == nil { throw MusicAddError.dtsStream }
        let folder = URL(filePath: encoding.folder, directoryHint: .isDirectory)
        let files = encoding.files.sorted { $0.track < $1.track }.map { folder.appending(path: $0.file) }
        if let missing = files.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
            throw MusicAddError.missing(missing)
        }
        return (files, encoding.format)
    }

    /// The album that the files are, as the first file's tags name it, to look for in Music
    /// (`MusicApp.find`), with the tracks of the earlier add that `record` keeps.
    public static func album(of files: [URL], record: RipReport.Encoding.MusicRecord? = nil) -> MusicApp.Album {
        let file = files.first.map(LibraryAlbum.readFile)
        let number = file?.tag("DISCNUMBER")
        let discs =
            number?.split(separator: "/").dropFirst().first.flatMap { Int($0) }
            ?? (file?.tag("DISCTOTAL") ?? file?.tag("TOTALDISCS")).flatMap { Int($0) }
        return MusicApp.Album(
            title: file?.tag("ALBUM") ?? "", artist: file?.tag("ALBUMARTIST") ?? file?.tag("ARTIST") ?? "",
            disc: (discs ?? 1) > 1 ? file?.discNumber : nil, trackIDs: record?.tracks ?? [])
    }

    /// Adds the files of one disc, in `format`, of the album folder `album`: as they are, or in
    /// a format that Music does not play, as copies.
    public func add(_ files: [URL], format: AudioFormat, album: URL) throws -> Added {
        guard !files.isEmpty else { throw MusicAddError.notEncoded }
        var made = [URL]()
        if !MusicApp.reads(format) {
            let folder = try copiesFolder(for: album, files: files)
            log(
                "Music cannot play \(format.name), so it gets \(self.format.name) copies, made in "
                    + Self.shown(folder) + ".")
            made = try copy(files, into: folder)
        }
        let tracks = try MusicApp.add(made.isEmpty ? files : made)
        let kept = removeCopies(made, addedAs: tracks)
        if !made.isEmpty {
            log(
                kept == 0
                    ? "Music copied them into its own folder, so Silverside's copies are deleted."
                    : "Music plays the copies where they are, so they stay.")
        }
        let record = RipReport.Encoding.MusicRecord(
            date: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
            format: made.isEmpty ? format : self.format, tracks: tracks.map(\.persistentID))
        return Added(
            record: record, tracks: tracks.isEmpty ? files.count : tracks.count, copies: made.count, keptCopies: kept)
    }

    /// Adds the files as `add` does, unless Music has the album already: the tracks of an earlier
    /// add (`record`), or tracks of its very title, artist, and disc. Then it throws
    /// `MusicAddError.inMusic`. For an add after encoding, which asks no one.
    public func addUnlessThere(
        _ files: [URL], format: AudioFormat, album: URL, record: RipReport.Encoding.MusicRecord? = nil
    ) throws -> Added {
        let wanted = Self.album(of: files, record: record)
        let found = try MusicApp.find(wanted)
        if found.hasAlbum(wanted) { throw MusicAddError.inMusic(found.description(of: wanted) ?? "") }
        return try add(files, format: format, album: album)
    }

    /// The folder of an album's copies: the album's place in the library, in `copies`; for an
    /// album outside the library, its folder's name. An add never replaces a file, so when a
    /// file there has the name of a copy of `files`, the copies go in "<name> 2", and so on.
    /// Folders are compared through symbolic links and other spellings: one in the library, or
    /// in the album's own folder, is refused.
    func copiesFolder(for album: URL, files: [URL] = []) throws -> URL {
        guard !Self.isWithin(copies, library) else { throw MusicAddError.copiesInLibrary(copies) }
        let root = library.standardizedFileURL.resolvingSymlinksInPath().path
        let path = album.standardizedFileURL.resolvingSymlinksInPath().path
        let place = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : album.lastPathComponent
        let first = copies.appending(path: place, directoryHint: .isDirectory)
        let names = files.map(Self.copyName)
        var number = 1
        while true {
            let folder =
                number == 1
                ? first
                : first.deletingLastPathComponent().appending(
                    path: "\(first.lastPathComponent) \(number)", directoryHint: .isDirectory)
            guard !Self.isWithin(folder, library) else { throw MusicAddError.copiesInLibrary(folder) }
            guard !Self.isWithin(folder, album) else { throw MusicAddError.copiesInAlbum(folder) }
            if !names.contains(where: { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }) {
                return folder
            }
            number += 1
        }
    }

    /// True if `folder` is `other` or inside it, through any symbolic link or other spelling of
    /// either, such as a case alias. `folder` need not be there yet.
    static func isWithin(_ folder: URL, _ other: URL) -> Bool {
        var path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        while true {
            if DiscEncoder.sameFile(URL(filePath: path, directoryHint: .isDirectory), other) { return true }
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != path else { return false }
            path = parent
        }
    }

    /// The name of a file's copy.
    static func copyName(_ file: URL) -> String { file.deletingPathExtension().lastPathComponent + ".m4a" }

    /// The copies of `files` in `folder`, a few at a time, each checked. When one fails, the
    /// copies made are deleted, with the folders that this leaves empty.
    func copy(_ files: [URL], into folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let targets = files.map { folder.appending(path: Self.copyName($0)) }
        let lanes = max(1, min(parallelTracks, files.count))
        let results = CopyResults()
        let (format, aac) = (self.format, self.aac)
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
            for index in stride(from: lane, to: files.count, by: lanes) where !results.failed {
                do {
                    try Self.convert(files[index], to: targets[index], format: format, aac: aac)
                    results.made(index)
                } catch {
                    results.add(index, error)
                }
            }
        }
        if let error = results.firstError {
            for index in results.madeIndexes { try? FileManager.default.removeItem(at: targets[index]) }
            removeEmptyFolders(from: folder)
            throw error
        }
        log(
            "Made \(files.count) cop\(files.count == 1 ? "y" : "ies"), "
                + (format.isLossless
                    ? "each checked to decode to exactly the audio of its file."
                    : "each checked to decode to its track's length."))
        return targets
    }

    /// Writes `source`, a FLAC file, as `target` in `format`, with its tags and cover: beside it
    /// first, checked, then in its place, which must be free. A lossless copy keeps every bit,
    /// and every channel.
    static func convert(_ source: URL, to target: URL, format: AudioFormat, aac: AACOptions) throws {
        let partial = target.deletingLastPathComponent()
            .appending(path: ".\(target.deletingPathExtension().lastPathComponent).partial.m4a")
        defer { try? FileManager.default.removeItem(at: partial) }
        let details = AudioDetails.read(source)?.format
        let bits = details?.bits ?? 24
        let matches: Bool
        if (details?.channels ?? 2) > 2 {
            var audio = try AudioEncoder.decodeSurround(source)
            audio.bits = bits <= 20 ? 20 : 24
            try AudioEncoder.encode(audio, format: format, to: partial, aac: aac)
            let decoded = try AudioEncoder.decodeSurround(partial, as: audio.channelMask)
            matches =
                decoded.map {
                    format.isLossless
                        ? $0.values == audio.values : abs($0.frameCount - audio.frameCount) < 4 * 1152
                } ?? false
        } else if bits > 16 {
            let values = try AudioEncoder.decodeWide(source)
            try AudioEncoder.encode(.wide(values), format: format, to: partial, aac: aac, bits: bits)
            let decoded = try AudioEncoder.decodeWide(partial)
            matches = format.isLossless ? decoded == values : abs(decoded.count - values.count) < 8 * 1152
        } else {
            let samples = try AudioEncoder.decode(source)
            try AudioEncoder.encode(samples, format: format, to: partial, aac: aac)
            let decoded = try AudioEncoder.decode(partial)
            matches = format.isLossless ? decoded == samples : abs(decoded.count - samples.count) < 4 * 1152
        }
        guard matches else { throw MusicAddError.copyFailed(source) }
        let comments = try FLACTags.read(source).map { (key: $0.key.uppercased(), value: $0.value) }
        let cover = try FLACTags.readFrontCover(source).flatMap { try? EmbeddedCover(CoverImage(data: $0)) }
        try MP4Tags.write(comments, cover: cover, to: partial)
        try FileManager.default.moveItem(at: partial, to: target)
    }

    /// Deletes the copies that Music copied into its own folder: when it named a file for each
    /// copy, none of them a copy, of the same sizes as the copies. Returns how many copies stay.
    func removeCopies(_ made: [URL], addedAs tracks: [MusicApp.Track]) -> Int {
        guard !made.isEmpty else { return 0 }
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1 }
        let theirs = tracks.compactMap(\.location)
        guard tracks.count == made.count, theirs.count == made.count,
            !theirs.contains(where: { music in made.contains { DiscEncoder.sameFile($0, music) } }),
            !theirs.contains(where: { size($0) < 0 }), theirs.map(size).sorted() == made.map(size).sorted()
        else { return made.count }
        var kept = 0
        for copy in made {
            do { try FileManager.default.removeItem(at: copy) } catch { kept += 1 }
        }
        removeEmptyFolders(from: made[0].deletingLastPathComponent())
        return kept
    }

    /// Removes the folder if it is empty (but for a .DS_Store), and each empty folder above it in `copies`.
    func removeEmptyFolders(from folder: URL) {
        let root = copies.standardizedFileURL.path
        var folder = folder.standardizedFileURL
        while folder.path.hasPrefix(root + "/") {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [""]
            guard names.allSatisfy({ $0 == ".DS_Store" }), (try? FileManager.default.removeItem(at: folder)) != nil
            else { return }
            folder = folder.deletingLastPathComponent()
        }
    }

    static func shown(_ folder: URL) -> String { (folder.path as NSString).abbreviatingWithTildeInPath }
}

/// The copies that failed, and their errors, and the copies made, from the threads that make them.
private final class CopyResults: @unchecked Sendable {
    private let lock = NSLock()
    private var errors = [Int: any Error]()
    private var done = Set<Int>()

    var failed: Bool { lock.withLock { !errors.isEmpty } }
    var firstError: (any Error)? { lock.withLock { errors.min { $0.key < $1.key }?.value } }
    var madeIndexes: Set<Int> { lock.withLock { done } }

    func add(_ index: Int, _ error: any Error) {
        lock.withLock { errors[index] = error }
    }

    func made(_ index: Int) {
        lock.withLock { _ = done.insert(index) }
    }
}

public enum MusicAddError: Error, Equatable, CustomStringConvertible {
    case notEncoded
    case dtsStream
    case missing(URL)
    case copiesInLibrary(URL)
    case copiesInAlbum(URL)
    case copyFailed(URL)
    /// Music has the album already: what it has, for people.
    case inMusic(String)

    public var description: String {
        switch self {
        case .notEncoded: "The rip is not encoded, so there is no album to add."
        case .dtsStream:
            "The album keeps the disc's DTS stream, which Music plays as noise. Decode the stream, and add the decoded album."
        case .missing(let file): "\(file.path) is not there: the album's files were moved or deleted."
        case .copiesInLibrary(let folder):
            "The copies for Music would go in the library (\(MusicAdd.shown(folder))). Choose a folder outside it."
        case .copiesInAlbum(let folder):
            "The copies for Music would go in the album's own folder (\(MusicAdd.shown(folder))). Choose a folder outside it."
        case .copyFailed(let file): "The copy of \(file.lastPathComponent) does not decode to the file's audio."
        case .inMusic(let found): "\(found) It is not added again."
        }
    }
}

extension RipReport.Encoding {
    /// Keeps an add to Music in the report at `file`: a rip's disc.json, or an album folder's
    /// report. A rip's album folder's report gets it too.
    public static func saveMusic(_ record: MusicRecord, reportAt file: URL) throws {
        let report = try RipReport.read(from: file)
        guard var encoding = report.encoding else { return }
        encoding.music = record
        try encoding.save(inReportAt: file)
        guard !isAlbumReport(file) else { return }
        let discPart =
            (report.release?.media.count ?? 1) > 1 ? report.discPosition.map { " (Disc \($0))" } ?? "" : ""
        let albumReport = URL(filePath: encoding.folder, directoryHint: .isDirectory)
            .appending(path: "Rip Report\(discPart).json")
        guard FileManager.default.fileExists(atPath: albumReport.path),
            var album = try RipReport.read(from: albumReport).encoding
        else { return }
        album.music = record
        try album.save(inReportAt: albumReport)
    }
}
