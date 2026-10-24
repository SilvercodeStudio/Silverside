import Foundation

/// The user's own cover for a release, kept by release ID beside the album edits, so that
/// every disc of a set gets it and a later rip of the same release finds it. One file for
/// each release, "<id>.jpg" or ".png", in Application Support.
public struct ReleaseCoverStore: Sendable {
    public let folder: URL

    public init(
        folder: URL = DriveProfileStore.defaultDirectory.appending(path: "ReleaseCovers", directoryHint: .isDirectory)
    ) {
        self.folder = folder
    }

    private func files(for releaseID: String) -> [URL] {
        let name = releaseID.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return ["jpg", "png"].map { folder.appending(path: "\(name).\($0)") }
    }

    public func cover(forReleaseID releaseID: String) -> CoverImage? {
        files(for: releaseID).lazy.compactMap { try? Data(contentsOf: $0) }.first.map(CoverImage.init)
    }

    public func remember(_ cover: CoverImage, forReleaseID releaseID: String) throws {
        guard let fileExtension = cover.fileExtension else { throw CoverArtError.unknownFormat }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try forget(releaseID: releaseID)
        try cover.data.write(to: files(for: releaseID).first { $0.pathExtension == fileExtension }!, options: .atomic)
    }

    public func forget(releaseID: String) throws {
        for file in files(for: releaseID) where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}

/// What a library update did to an encoded album.
public struct LibraryUpdate: Sendable {
    /// The encoded files, with their names after the update, in track order.
    public var files: [URL]
    /// Files and folders that were renamed or moved.
    public var renamed: Int
    /// The album folder after the update; nil when the rip has not been encoded.
    public var albumFolder: URL?
}

extension DiscEncoder {
    /// Writes a new cover, and the current names, into an encoded album's files (see `updateLibrary`).
    @discardableResult
    public func retag(reportAt file: URL, cover: CoverImage? = nil, remember: Bool = true, library: URL? = nil) throws
        -> [URL]
    {
        try updateLibrary(reportAt: file, cover: cover, remember: remember, library: library).files
    }

    /// Brings an encoded album up to date with the release's current names and cover, without
    /// touching the audio: the tags of every file are written again, files and the album
    /// folder are renamed as the templates now name them, the CUE sheet is written again,
    /// and the reports record it. The names are the release's with the edits kept for it
    /// (`ReleaseEditsStore`, which every disc of a set shares) over the rip's own, so a change
    /// made on one disc reaches the others. `file` is a rip's `disc.json`, or the album
    /// folder's "Rip Report.json" after the rip's files were deleted. A new `cover` replaces
    /// the cover file in the rip's folder and the album's, and is kept for the release (unless
    /// `remember` is false, as when the archive's own cover is put back). A rip's `disc.json`
    /// records its encoding only when the rip itself encoded; for one encoded later, the album
    /// folder in `library`, named as this encoder names it, is looked at. A rip not yet
    /// encoded gets the cover file only.
    public func updateLibrary(
        reportAt file: URL, cover: CoverImage? = nil, remember: Bool = true, library: URL? = nil,
        editsStore: ReleaseEditsStore = ReleaseEditsStore(), coverStore: ReleaseCoverStore = ReleaseCoverStore()
    ) throws -> LibraryUpdate {
        var report = try RipReport.read(from: file)
        let folder = file.deletingLastPathComponent()
        let isRipFolder = file.lastPathComponent == "disc.json"
        guard let original = report.release else { throw EncodingError.noRelease(folder) }
        let toc = try TOC(ctdbTOCString: report.toc)

        // The names: the rip's edits, with the release's kept album names on top.
        var edits = Self.edits(inReportAt: file) ?? MetadataEdits()
        if !original.isManual, let kept = editsStore.edits(forReleaseID: original.id) {
            edits = edits.merged(with: kept)
        }
        let release = edits.applied(to: original, toc: toc)
        guard let medium = release.medium(for: toc) else { throw EncodingError.unknownMedium(folder) }
        let discPart = release.media.count > 1 ? " (Disc \(medium.position))" : ""

        // The album folder: the encoding's, or for a rip encoded from the terminal, the one the
        // templates name: with the names as they are now, else as the rip alone had them, else
        // as MusicBrainz has them, since the album may have been renamed since it was encoded.
        if report.encoding == nil, let library {
            let ripEdits = Self.edits(inReportAt: file) ?? MetadataEdits()
            for candidate in [release, ripEdits.applied(to: original, toc: toc), original] {
                guard let candidateMedium = candidate.medium(for: toc), let first = candidateMedium.tracks.first
                else { continue }
                let values = metadata(release: candidate, medium: candidateMedium, track: first, isrc: nil).nameValues
                let album = library.appending(path: folderTemplate.name(values), directoryHint: .isDirectory)
                let saved = album.appending(path: "Rip Report\(discPart).json")
                if let encoding = (try? RipReport.read(from: saved))?.encoding {
                    report.encoding = encoding
                    break
                }
            }
        }
        var albumFolder = report.encoding.map { URL(filePath: $0.folder, directoryHint: .isDirectory) }

        // The cover: the new one into every folder the album has, else the one there already.
        var coverFile: URL?
        if let cover {
            for destination in [isRipFolder ? folder : nil, albumFolder].compactMap({ $0 })
            where FileManager.default.fileExists(atPath: destination.path) {
                for old in ["cover.jpg", "cover.png"].map({ destination.appending(path: $0) })
                where FileManager.default.fileExists(atPath: old.path) {
                    try FileManager.default.removeItem(at: old)
                }
                coverFile = try cover.write(to: destination)
            }
            if remember, !release.isManual { try coverStore.remember(cover, forReleaseID: release.id) }
        } else {
            coverFile = [albumFolder, folder].compactMap { $0 }
                .flatMap { folder in ["cover.jpg", "cover.png"].map { folder.appending(path: $0) } }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        if isRipFolder, !edits.isEmpty { try edits.save(inDiscJSONOf: folder) }
        guard var encoding = report.encoding, let current = albumFolder else {
            return LibraryUpdate(files: [], renamed: 0, albumFolder: nil)
        }
        var renamed = 0

        // The album folder, as the templates name it now. A set shares one folder, so a move
        // into a folder that exists merges into it.
        if let library, let first = medium.tracks.first {
            let values = metadata(release: release, medium: medium, track: first, isrc: nil).nameValues
            let planned = library.appending(path: folderTemplate.name(values), directoryHint: .isDirectory)
            if planned.standardizedFileURL != current.standardizedFileURL,
                FileManager.default.fileExists(atPath: current.path)
            {
                if FileManager.default.fileExists(atPath: planned.path) {
                    for name in try FileManager.default.contentsOfDirectory(atPath: current.path)
                    where name != ".DS_Store" {
                        let destination = planned.appending(path: name)
                        if !FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.moveItem(at: current.appending(path: name), to: destination)
                        }
                    }
                    try? FileManager.default.removeItem(at: current)
                } else {
                    try FileManager.default.createDirectory(
                        at: planned.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: current, to: planned)
                }
                albumFolder = planned
                renamed += 1
            }
        }
        let album = albumFolder ?? current
        coverFile =
            ["cover.jpg", "cover.png"].map { album.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) } ?? coverFile
        let embedded = try coverFile.map { try EmbeddedCover(CoverImage(data: Data(contentsOf: $0))) }

        // Each file: its name as the template has it now, then its tags.
        let audioTracks = toc.audioTracks
        var files = [URL]()
        var cueTracks = [CueSheet.Track]()
        var hiddenTrackFile: String?
        for index in encoding.files.indices {
            let entry = encoding.files[index]
            var url = album.appending(path: entry.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let trackIndex = entry.track == 0 ? 0 : audioTracks.firstIndex { $0.number == entry.track }
            guard let trackIndex, medium.tracks.indices.contains(trackIndex) else {
                throw EncodingError.unknownMedium(folder)
            }
            let track =
                entry.track == 0
                ? medium.hiddenTrack
                    ?? .init(
                        position: 0, number: "0", title: "Hidden Track", length: nil,
                        artistCredit: release.artistCredit,
                        recordingID: nil)
                : medium.tracks[trackIndex]
            let reported = report.tracks.first { $0.number == entry.track }
            let meta = metadata(release: release, medium: medium, track: track, isrc: reported?.isrc)
            let plannedName = trackTemplate.name(meta.nameValues) + "." + url.pathExtension
            if plannedName != entry.file {
                let destination = album.appending(path: plannedName)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.moveItem(at: url, to: destination)
                    url = destination
                    encoding.files[index].file = plannedName
                    renamed += 1
                }
            }
            let gain = encoding.replayGain
            let comments =
                meta.vorbisComments
                + ReplayGain.tags(track: gain?.tracks.first { $0.track == entry.track }?.values, album: gain?.album)
            switch encoding.format {
            case .flac: try FLACTags.write(comments, cover: embedded, to: url)
            case .alac, .aac: try MP4Tags.write(comments, cover: embedded, to: url)
            case .aiff: try ChunkTags.writeAIFF(comments, cover: embedded, to: url)
            case .wav: try ChunkTags.writeWAV(comments, cover: embedded, to: url)
            case .mp3: try ID3Tags.write(comments, cover: embedded, to: url)
            }
            files.append(url)
            if entry.track == 0 {
                hiddenTrackFile = url.lastPathComponent
                continue
            }
            let tocTrack = audioTracks[trackIndex]
            cueTracks.append(
                CueSheet.Track(
                    number: tocTrack.number, file: url.lastPathComponent, sectors: toc.sectorRange(of: tocTrack).count,
                    pregapSectors: reported?.pregapSectors ?? 0, title: meta.title,
                    performer: meta.vorbisComments.first { $0.key == "ARTIST" }?.value, isrc: reported?.isrc,
                    preEmphasis: tocTrack.hasPreEmphasis, copyPermitted: tocTrack.isCopyPermitted))
        }
        encoding.folder = album.path

        // The CUE sheet again, under its new name, and the reports.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: album.path)) ?? []
        where name.hasSuffix(".cue") && (discPart.isEmpty || name.hasSuffix(discPart + ".cue")) {
            try FileManager.default.removeItem(at: album.appending(path: name))
        }
        if !cueTracks.isEmpty {
            try writeCueSheet(
                cueTracks, hiddenTrackFile: hiddenTrackFile, release: release, medium: medium, toc: toc,
                mcn: report.mcn, to: album, discPart: discPart)
        }
        let albumReport = album.appending(path: "Rip Report\(discPart).json")
        if FileManager.default.fileExists(atPath: albumReport.path) {
            try encoding.save(inReportAt: albumReport)
            try Self.saveEdits(edits, inReportAt: albumReport)
            var shown = report
            shown.release = release
            shown.encoding = encoding
            try Data(shown.markdown.utf8).write(to: album.appending(path: "Rip Report\(discPart).md"))
        }
        if isRipFolder, report.encoding != nil { try encoding.save(inReportAt: file) }
        return LibraryUpdate(files: files, renamed: renamed, albumFolder: album)
    }

    private func metadata(
        release: MusicBrainzRelease, medium: MusicBrainzRelease.Medium, track: MusicBrainzRelease.Track, isrc: String?
    ) -> TrackMetadata {
        TrackMetadata(
            release: release, medium: medium, track: track, isrc: isrc, liveShowStyle: liveShowStyle,
            plainPunctuation: plainPunctuation, segueMarks: segueMarks, compilationFolder: compilationFolder)
    }

    /// The "edits" beside a report, in a rip's disc.json or the album folder's copy of it.
    static func edits(inReportAt file: URL) -> MetadataEdits? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
            let edits = object["edits"]
        else { return nil }
        return try? JSONDecoder().decode(MetadataEdits.self, from: JSONSerialization.data(withJSONObject: edits))
    }

    /// Sets "edits" in a report file, and keeps every other key.
    static func saveEdits(_ edits: MetadataEdits, inReportAt url: URL) throws {
        var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        if edits.isEmpty {
            object["edits"] = nil
        } else {
            object["edits"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edits))
        }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
