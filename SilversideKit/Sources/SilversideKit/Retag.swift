import Foundation

/// The user's own cover for a release, kept by release ID beside the album edits, so that
/// every disc of a set gets it and a later rip of the same release finds it. One file for
/// each release, "<id>.jpg" or ".png", in Application Support. For a box set whose discs
/// each have their own sleeve in the Cover Art Archive, "<id>.sleeves" says that each disc
/// takes its sleeve (see `CoverArtImage.sleeve`); the cover, if any, stays the set's.
public struct ReleaseCoverStore: Sendable {
    public let folder: URL

    public init(
        folder: URL = DriveProfileStore.defaultDirectory.appending(path: "ReleaseCovers", directoryHint: .isDirectory)
    ) {
        self.folder = folder
    }

    private func files(for releaseID: String) -> [URL] {
        ["jpg", "png"].map { folder.appending(path: "\(Self.name(releaseID)).\($0)") }
    }

    private func sleevesFile(for releaseID: String) -> URL {
        folder.appending(path: "\(Self.name(releaseID)).sleeves")
    }

    private static func name(_ releaseID: String) -> String {
        releaseID.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }

    /// True if each disc of the release takes its own sleeve from the Cover Art Archive.
    public func usesDiscSleeves(releaseID: String) -> Bool {
        FileManager.default.fileExists(atPath: sleevesFile(for: releaseID).path)
    }

    /// Each disc of the release takes its own sleeve from now on (or, with `false`, the set's cover).
    public func useDiscSleeves(_ uses: Bool, releaseID: String) throws {
        let file = sleevesFile(for: releaseID)
        if uses {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: file)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    public func cover(forReleaseID releaseID: String) -> CoverImage? {
        files(for: releaseID).lazy.compactMap { try? Data(contentsOf: $0) }.first.map(CoverImage.init)
    }

    /// Keeps a cover for every disc of the release, in place of any disc's own sleeve.
    public func remember(_ cover: CoverImage, forReleaseID releaseID: String) throws {
        guard let fileExtension = cover.fileExtension else { throw CoverArtError.unknownFormat }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try forget(releaseID: releaseID)
        try cover.data.write(to: files(for: releaseID).first { $0.pathExtension == fileExtension }!, options: .atomic)
    }

    /// Forgets the cover and the discs' sleeves: the release takes the archive's main front again.
    public func forget(releaseID: String) throws {
        for file in files(for: releaseID) where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        try useDiscSleeves(false, releaseID: releaseID)
    }
}

/// What a library update does with a disc's own cover (a box set's sleeve, "cover (Disc 2).jpg").
public enum DiscCoverChange: Sendable {
    /// Leaves it as it is.
    case keep
    /// The disc's files embed this, in place of the album's cover.
    case set(CoverImage)
    /// The disc takes the album's cover again.
    case remove
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
    public func retag(
        reportAt file: URL, cover: CoverImage? = nil, remember: Bool = true, discCover: DiscCoverChange = .keep,
        library: URL? = nil
    ) throws -> [URL] {
        try updateLibrary(reportAt: file, cover: cover, remember: remember, discCover: discCover, library: library)
            .files
    }

    /// Brings an encoded album up to date with the release's current names and cover, without
    /// touching the audio: the tags of every file are written again, files and the album
    /// folder are renamed as the templates now name them, the CUE sheet is written again,
    /// and the reports record it. The names are the release's with the edits kept for it
    /// (`ReleaseEditsStore`, which every disc of a set shares) over the rip's own, so a change
    /// made on one disc reaches the others. `file` is a rip's `disc.json`, or the album
    /// folder's "Rip Report.json" after the rip's files were deleted. A new `cover` replaces
    /// the cover file in the rip's folder and the album's, and is kept for the release (unless
    /// `remember` is false, as when the archive's own cover is put back). `discCover` sets or
    /// removes the disc's own cover, which its files embed in place of the album's. A rip's `disc.json`
    /// records its encoding only when the rip itself encoded; for one encoded later, the album
    /// folder in `library`, named as this encoder names it, is looked at. A rip not yet
    /// encoded gets the cover file only.
    public func updateLibrary(
        reportAt file: URL, cover: CoverImage? = nil, remember: Bool = true, discCover: DiscCoverChange = .keep,
        library: URL? = nil, editsStore: ReleaseEditsStore = ReleaseEditsStore(),
        coverStore: ReleaseCoverStore = ReleaseCoverStore()
    ) throws -> LibraryUpdate {
        var report = try RipReport.read(from: file)
        let folder = file.deletingLastPathComponent()
        let isRipFolder = file.lastPathComponent == "disc.json"
        guard let original = report.release else { throw EncodingError.noRelease(folder) }
        let toc = try TOC(ctdbTOCString: report.toc)

        // The names: the rip's edits, with the release's kept album names on top.
        let edits = MetadataEdits.current(forReportAt: file, release: original, store: editsStore)
        var release = edits.applied(to: original, toc: toc)
        guard let medium = release.medium(for: toc) else { throw EncodingError.unknownMedium(folder) }
        let discPart = release.media.count > 1 ? " (Disc \(medium.position))" : ""

        // The album folder: the encoding's, or for a rip encoded from the terminal, the one the
        // templates name: with the names as they are now, else as the rip alone had them, else
        // as MusicBrainz has them, since the album may have been renamed since it was encoded.
        if report.encoding == nil, let library {
            let ripEdits = MetadataEdits.read(fromReportAt: file) ?? MetadataEdits()
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
        // A decoded copy beside the album keeps its title's suffix, and so its own folder.
        if let suffix = report.encoding?.albumSuffix { release.title += suffix }

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
        // The disc's own cover (a box set's sleeve), beside the album's in each folder.
        for destination in [isRipFolder ? folder : nil, albumFolder].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: destination.path) {
            switch discCover {
            case .keep: break
            case .set(let own): try CoverFiles.writeDisc(own, position: medium.position, in: destination)
            case .remove: try CoverFiles.removeDisc(medium.position, in: destination)
            }
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
        coverFile = CoverFiles.embedded(forDisc: medium.position, in: album) ?? coverFile
        let embedded = try coverFile.map { try EmbeddedCover(CoverImage(data: Data(contentsOf: $0))) }

        // ReplayGain: the album's gain is the whole release's once every disc is in the album
        // folder. A record from before histograms were kept is measured from its files.
        if var gain = encoding.replayGain {
            if gain.histogram == nil { gain.histogram = try? Self.measuredHistogram(of: encoding, in: album) }
            let whole = gain.histogram.flatMap {
                Self.releaseGain(of: release, in: album, disc: (medium.position, $0))
            }
            gain.release = whole?.values
            gain.releaseDiscs = whole?.discs
            encoding.replayGain = gain
        }

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
                meta.vorbisComments + HDCDStatus.tags(report.hdcd, decoded: encoding.hdcdDecoded == true)
                + PreEmphasis.tags(
                    hasPreEmphasis: (entry.track == 0 ? report.tracks.first : reported)?.preEmphasis == true,
                    deEmphasized: encoding.deEmphasizedTracks?.contains(entry.track) == true)
                + ReplayGain.tags(
                    track: gain?.tracks.first { $0.track == entry.track }?.values, album: gain?.albumInTags)
            // A file whose tags are already these is left alone (a library on a network
            // volume is slow to write), unless the cover changes.
            let coverChanges: Bool
            if case .keep = discCover { coverChanges = cover != nil } else { coverChanges = true }
            if coverChanges || Self.comments(of: url, format: encoding.format).map({ !Self.same($0, comments) }) ?? true
            {
                switch encoding.format {
                case .flac: try FLACTags.write(comments, cover: embedded, to: url)
                case .alac, .aac: try MP4Tags.write(comments, cover: embedded, to: url)
                case .aiff: try ChunkTags.writeAIFF(comments, cover: embedded, to: url)
                case .wav: try ChunkTags.writeWAV(comments, cover: embedded, to: url)
                case .mp3: try ID3Tags.write(comments, cover: embedded, to: url)
                }
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
                    // The TOC here comes from the report's CTDB TOC string, which has no flags.
                    preEmphasis: tocTrack.hasPreEmphasis || reported?.preEmphasis == true,
                    copyPermitted: tocTrack.isCopyPermitted || reported?.isCopyPermitted == true))
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
            try edits.save(inReportAt: albumReport)
            var shown = report
            shown.release = release
            shown.encoding = encoding
            try Data(shown.markdown.utf8).write(to: album.appending(path: "Rip Report\(discPart).md"))
        }
        if isRipFolder, report.encoding != nil { try encoding.save(inReportAt: file) }
        return LibraryUpdate(files: files, renamed: renamed, albumFolder: album)
    }

    /// The tags of a FLAC or MP4 file, as the writer would give them; nil for other formats or a file that cannot be read.
    private static func comments(of url: URL, format: AudioFormat) -> [(key: String, value: String)]? {
        switch format {
        case .flac: try? FLACTags.read(url)
        case .alac, .aac: try? MP4Tags.read(url).comments
        case .aiff, .wav, .mp3: nil
        }
    }

    private static func same(_ a: [(key: String, value: String)], _ b: [(key: String, value: String)]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    // MARK: ReplayGain for a set

    /// The album's ReplayGain over every CD of a multi-disc release, from the discs' reports
    /// in `album` ("Rip Report (Disc N).json"), once every CD of the release is encoded there.
    /// Nil before then, for a release of one CD, and when a disc was encoded without
    /// ReplayGain. `disc` stands in for its position's report: the disc being encoded or
    /// updated. A report from before histograms were kept is measured from its files once,
    /// and the histogram is saved in it.
    static func releaseGain(
        of release: MusicBrainzRelease, in album: URL, disc: (position: Int, histogram: ReplayGain.Histogram)?
    ) -> (values: ReplayGain.Values, discs: Int)? {
        let positions = release.cdPositions
        guard positions.count > 1 else { return nil }
        var histograms = [Int: ReplayGain.Histogram]()
        if let disc { histograms[disc.position] = disc.histogram }
        for (file, report) in albumReports(of: release, in: album) {
            guard let position = report.discPosition, histograms[position] == nil, positions.contains(position),
                var encoding = report.encoding
            else { continue }
            guard var gain = encoding.replayGain else { return nil }
            if gain.histogram == nil {
                guard let measured = try? measuredHistogram(of: encoding, in: album) else { return nil }
                gain.histogram = measured
                encoding.replayGain = gain
                try? encoding.save(inReportAt: file)
            }
            histograms[position] = gain.histogram
        }
        guard positions.allSatisfy({ histograms[$0] != nil }),
            let values = ReplayGain.album(of: positions.compactMap { histograms[$0] })
        else { return nil }
        return (values, positions.count)
    }

    /// The reports of the release's discs in an album folder.
    static func albumReports(of release: MusicBrainzRelease, in album: URL) -> [(file: URL, report: RipReport)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: album.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasPrefix("Rip Report"), name.hasSuffix(".json") else { return nil }
            let file = album.appending(path: name)
            guard let report = try? RipReport.read(from: file), report.release?.id == release.id else { return nil }
            return (file, report)
        }
    }

    /// A disc's blocks, measured from its encoded files.
    static func measuredHistogram(of encoding: RipReport.Encoding, in album: URL) throws -> ReplayGain.Histogram {
        let measured = CTDB.parallelMap(over: encoding.files, lanes: defaultParallelTracks) {
            entry -> Result<ReplayGain.Analysis, any Error>? in
            let file = album.appending(path: entry.file)
            return Result {
                encoding.hdcdDecoded == true || encoding.deEmphasizedTracks?.contains(entry.track) == true
                    ? ReplayGain.analyze(.wide(try AudioEncoder.decodeWide(file)))
                    : ReplayGain.analyze(try AudioEncoder.decode(file))
            }
        }
        return ReplayGain.Histogram(try measured.map { try $0.get() })
    }

    /// After a disc's encoding: the other discs of its release in the album folder take the
    /// whole release's album gain, if it changed (`updateLibrary` writes it). Each disc that
    /// cannot be updated is logged, and the encoding stands.
    func updateReleaseGain(
        _ values: ReplayGain.Values, of release: MusicBrainzRelease, in album: URL, except position: Int, library: URL
    ) {
        for (file, report) in Self.albumReports(of: release, in: album) {
            guard let other = report.discPosition, other != position, report.encoding?.replayGain != nil,
                report.encoding?.replayGain?.release != values
            else { continue }
            do {
                _ = try updateLibrary(reportAt: file, library: library)
                log("Disc \(other): album gain \(values.gainText), over all \(release.cdPositions.count) discs")
            } catch {
                log("Disc \(other): the album gain could not be written: \(error)")
            }
        }
    }

    private func metadata(
        release: MusicBrainzRelease, medium: MusicBrainzRelease.Medium, track: MusicBrainzRelease.Track, isrc: String?
    ) -> TrackMetadata {
        TrackMetadata(
            release: release, medium: medium, track: track, isrc: isrc, liveShowStyle: liveShowStyle,
            plainPunctuation: plainPunctuation, segueMarks: segueMarks, compilationFolder: compilationFolder)
    }
}
