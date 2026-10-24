import Foundation

/// A ripped disc in a folder: its WAV files and its disc.json, as `silverside rip` writes it or
/// as the archive keeps it.
public struct RippedDisc: Sendable {
    public struct Track: Sendable {
        public var number: Int
        public var file: URL
        /// True if AccurateRip or CTDB proves the track, or the archive marks the disc complete
        /// (the rule of `RipReport.isVerified`).
        public var isVerified: Bool
        public var isrc: String?
    }

    public var folder: URL
    public var toc: TOC
    /// The release with the rip's edits applied (see `MetadataEdits`).
    public var release: MusicBrainzRelease?
    /// The rip's edits, if disc.json has any.
    public var edits: MetadataEdits?
    public var tracks: [Track]
    /// The rip's report, if the folder has one (rips before reports, in the archive, do not).
    public var report: RipReport?

    /// Deletes the files that the rip wrote in its folder, as its report lists them (the WAV
    /// files, the suspects, the reports, and the artwork), and nothing else. Then the Artwork
    /// folder and the rip's folder go too, if nothing else is in them. A rip from before
    /// reports listed their files loses the files that a rip writes, by name.
    public func deleteRipFiles() throws {
        let manager = FileManager.default
        var files: [URL]
        if let listed = report?.files {
            files = listed.map { folder.appending(path: $0) }
        } else {
            files = tracks.flatMap { track in
                [track.file, folder.appending(path: TrackAudio.alternativesFileName(track: track.number))]
            }
            files += ["disc.json", "Rip Report.md", "cover.jpg", "cover.png", "Artwork"].map {
                folder.appending(path: $0)
            }
        }
        files += [RipFolder.claimFile, RipFolder.oldClaimFile].map { folder.appending(path: $0) }
        for file in files where manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
        for directory in [folder.appending(path: "Artwork"), folder] {
            let contents = try? manager.contentsOfDirectory(atPath: directory.path)
            if contents?.allSatisfy({ $0 == ".DS_Store" }) == true { try manager.removeItem(at: directory) }
        }
    }

    /// The folder's cover image (cover.jpg or cover.png), if it has one.
    public var coverFile: URL? {
        ["cover.jpg", "cover.png"].map { folder.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public init(folder: URL) throws {
        self.folder = folder
        let data = try Data(contentsOf: folder.appending(path: "disc.json"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tocString = object["toc"] as? String
        else { throw EncodingError.noDiscJSON(folder) }
        toc = try TOC(ctdbTOCString: tocString)
        release = try (object["release"]).map {
            try JSONDecoder().decode(MusicBrainzRelease.self, from: JSONSerialization.data(withJSONObject: $0))
        }
        edits = try (object["edits"]).map {
            try JSONDecoder().decode(MetadataEdits.self, from: JSONSerialization.data(withJSONObject: $0))
        }
        if let edits, let original = release { release = edits.applied(to: original, toc: toc) }
        // A rip's report is disc.json itself, or the archive's "ripReport".
        let report = (object["ripReport"] as? [String: Any]) ?? (object["tracks"] != nil ? object : nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.report = try? report.map {
            try decoder.decode(RipReport.self, from: JSONSerialization.data(withJSONObject: $0))
        }
        if let report, let reportTracks = report["tracks"] as? [[String: Any]] {
            let ctdb = (report["ctdb"] as? [String: Any])?["status"] as? String
            let wholeDisc = ctdb == "verified" || ctdb == "repaired"
            let hidden = self.report?.hiddenTrack.map {
                Track(number: 0, file: folder.appending(path: $0.file), isVerified: $0.readsAgree, isrc: nil)
            }
            tracks =
                (hidden.map { [$0] } ?? [])
                + reportTracks.compactMap { track in
                    guard let number = track["number"] as? Int, let file = track["file"] as? String else { return nil }
                    let accurateRip = track["accurateRip"] as? String
                    let ctdbConfidence = track["ctdbConfidence"] as? Int ?? 0
                    return Track(
                        number: number, file: folder.appending(path: file),
                        isVerified: wholeDisc || accurateRip == "accurate" || accurateRip == "otherPressings"
                            || ctdbConfidence > 0,
                        isrc: track["isrc"] as? String)
                }
        } else {
            // An archive manifest from before rips had reports: one WAV for each audio track.
            let complete = object["complete"] as? Bool ?? false
            tracks = toc.audioTracks.map {
                Track(
                    number: $0.number, file: folder.appending(path: String(format: "Track %02d.wav", $0.number)),
                    isVerified: complete, isrc: nil)
            }
        }
    }
}

public enum EncodingError: Error, Equatable, CustomStringConvertible {
    case noDiscJSON(URL)
    case noRelease(URL)
    case unknownMedium(URL)
    case notVerified(track: Int)
    case exists(URL)
    case verificationFailed(URL)

    public var description: String {
        switch self {
        case .noDiscJSON(let folder): "\(folder.path) has no disc.json with a TOC."
        case .noRelease(let folder):
            "\(folder.path) has no MusicBrainz release. Add one with silverside metadata -i \"\(folder.path)\"."
        case .unknownMedium(let folder): "Which disc of the release \(folder.path) holds is not clear."
        case .notVerified(let track):
            "Track \(track) is not verified by AccurateRip or CTDB. Use --allow-unverified to encode it anyway."
        case .exists(let file): "\(file.path) exists. Use --overwrite to replace it."
        case .verificationFailed(let file): "\(file.path) does not decode to the ripped audio."
        }
    }
}

/// Encodes a ripped disc into a music library: one file for each track, named and tagged
/// from the release, checked against the rip, with the cover in the album folder.
public struct DiscEncoder: Sendable {
    public var format: AudioFormat
    public var folderTemplate = NameTemplate.libraryFolder
    public var trackTemplate = NameTemplate.libraryTrack
    public var liveShowStyle = true
    /// Typographic punctuation becomes ASCII in names and tags.
    public var plainPunctuation = false
    public var segueMarks = SegueMarks.tagsOnly
    /// The album artist for names on a compilation, in place of "Various Artists". Empty keeps it.
    public var compilationFolder = ""
    public var aac = AACOptions()
    public var mp3 = MP3Options()
    /// Encode tracks that AccurateRip and CTDB do not prove.
    public var allowsUnverified = false
    /// Replace files that exist.
    public var overwrites = false
    /// Write ReplayGain tags: each track's gain and peak, and the album's, measured as EBU R 128 does.
    public var replayGain = true
    /// How many tracks encode at once. Each track in flight holds its audio twice (the rip and
    /// the decoded check), about 300 MB for a long track, so the default stays at four even on
    /// a Mac with many cores: half the cores, at least two, at most four.
    public var parallelTracks = DiscEncoder.defaultParallelTracks

    public static var defaultParallelTracks: Int {
        max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    }
    /// Receives a line for each track, for people to read.
    public var log: @Sendable (String) -> Void = { _ in }
    /// Hears each track when its file is written and checked: the track's number and the file.
    public var trackEncoded: @Sendable (_ number: Int, _ file: URL) -> Void = { _, _ in }

    public init(format: AudioFormat) {
        self.format = format
    }

    /// An encoder as the settings describe it: the format (unless `format` is given), the
    /// name templates, the styles, and the AAC and MP3 options.
    public init(settings: Settings, format: AudioFormat? = nil) {
        self.init(format: format ?? settings.format)
        folderTemplate = NameTemplate(settings.folderTemplate)
        trackTemplate = NameTemplate(settings.trackTemplate)
        liveShowStyle = settings.liveShowStyle
        plainPunctuation = settings.plainPunctuation
        segueMarks = settings.segueMarks
        compilationFolder = settings.compilationFolder
        aac = settings.aac
        mp3 = settings.mp3
        replayGain = settings.replayGain
    }

    /// The files that `encode` would write, one for each track, in order. It throws as `encode`
    /// does for a disc that cannot be encoded, but not for files that exist, so a caller can
    /// ask before it replaces them (see `overwrites`).
    public func plannedFiles(_ disc: RippedDisc, into library: URL) throws -> [URL] {
        try plan(disc, into: library).jobs.map(\.file)
    }

    private struct Job: Sendable {
        var ripped: RippedDisc.Track
        var index: Int
        var metadata: TrackMetadata
        var folder: URL
        var file: URL
        /// Tags beyond the metadata's: the ReplayGain values, once every track is measured.
        var extraComments: [(key: String, value: String)] = []
    }

    /// Every track's names, before any file is written.
    private func plan(_ disc: RippedDisc, into library: URL) throws -> (
        release: MusicBrainzRelease, medium: MusicBrainzRelease.Medium, jobs: [Job]
    ) {
        guard let release = disc.release else { throw EncodingError.noRelease(disc.folder) }
        guard let medium = release.medium(for: disc.toc) else { throw EncodingError.unknownMedium(disc.folder) }
        if !allowsUnverified, let track = disc.tracks.first(where: { !$0.isVerified }) {
            throw EncodingError.notVerified(track: track.number)
        }
        let audioTracks = disc.toc.audioTracks
        var jobs = [Job]()
        for ripped in disc.tracks {
            // Track 0 is the audio before track 1: MusicBrainz's pregap track, if it lists one.
            let index = ripped.number == 0 ? 0 : audioTracks.firstIndex { $0.number == ripped.number }
            guard let index, medium.tracks.indices.contains(index) else {
                throw EncodingError.unknownMedium(disc.folder)
            }
            let track =
                ripped.number == 0
                ? medium.hiddenTrack
                    ?? .init(
                        position: 0, number: "0", title: "Hidden Track", length: nil,
                        artistCredit: release.artistCredit,
                        recordingID: nil)
                : medium.tracks[index]
            let metadata = TrackMetadata(
                release: release, medium: medium, track: track, isrc: ripped.isrc, liveShowStyle: liveShowStyle,
                plainPunctuation: plainPunctuation, segueMarks: segueMarks, compilationFolder: compilationFolder)
            let values = metadata.nameValues
            let folder = library.appending(path: folderTemplate.name(values), directoryHint: .isDirectory)
            let file = folder.appending(path: trackTemplate.name(values) + "." + format.fileExtension)
            jobs.append(Job(ripped: ripped, index: index, metadata: metadata, folder: folder, file: file))
        }
        return (release, medium, jobs)
    }

    /// Encodes the disc's tracks into `library`, and returns the files written.
    @discardableResult
    public func encode(_ disc: RippedDisc, into library: URL) throws -> [URL] {
        try encodeWithRecord(disc, into: library).files
    }

    /// Encodes the disc's tracks into `library`, and returns the files written and the record
    /// of the encoding, which the album folder's report keeps too.
    public func encodeWithRecord(
        _ disc: RippedDisc, into library: URL
    ) throws -> (files: [URL], encoding: RipReport.Encoding?) {
        let encodingStarted = Date()
        var (release, medium, jobs) = try plan(disc, into: library)
        let lame = format == .mp3 ? MP3Encoder.lame() : nil
        if format == .mp3 && lame == nil { throw MP3Error.lameNotFound }
        // A file that exists stops the encoding before any file is written, so a half-done
        // album can be finished later.
        if !overwrites, let job = jobs.first(where: { FileManager.default.fileExists(atPath: $0.file.path) }) {
            throw EncodingError.exists(job.file)
        }

        let cover = try disc.coverFile.map { try EmbeddedCover(CoverImage(data: Data(contentsOf: $0))) }
        let audioTracks = disc.toc.audioTracks

        // ReplayGain needs every track's loudness before the first tag is written: the album's
        // gain is one gating over all of them. The tracks are measured from their WAV files,
        // `parallelTracks` at a time as they encode, since each holds its track's audio.
        // For the last disc of a multi-disc release into the album folder, the album is the whole release.
        var replayGainRecord: RipReport.Encoding.ReplayGainRecord?
        if replayGain {
            let measured = CTDB.parallelMap(over: jobs, lanes: parallelTracks) {
                job -> Result<ReplayGain.Analysis, any Error>? in
                Result { ReplayGain.analyze(try WAVFile.read(job.ripped.file)) }
            }
            let analyses = try measured.map { try $0.get() }
            let album = ReplayGain.album(of: analyses)
            let histogram = ReplayGain.Histogram(analyses)
            let whole = jobs.first.flatMap {
                Self.releaseGain(of: release, in: $0.folder, disc: (medium.position, histogram))
            }
            var tracks = [RipReport.Encoding.ReplayGainRecord.Track]()
            for (index, analysis) in analyses.enumerated() {
                let track = analysis.loudness.map { ReplayGain.Values(loudness: $0, peak: analysis.peak) }
                jobs[index].extraComments = ReplayGain.tags(track: track, album: whole?.values ?? album)
                if let track { tracks.append(.init(track: jobs[index].ripped.number, values: track)) }
            }
            replayGainRecord = .init(
                album: album, tracks: tracks, histogram: histogram, release: whole?.values, releaseDiscs: whole?.discs)
        }

        // The tracks encode `parallelTracks` at a time. Each lane takes every n-th job, in
        // order, so the lanes keep in step and no more than that many tracks are in memory.
        // A failure stops the lanes after the tracks under way; the files written stay, as
        // they did when the tracks went one by one.
        let lanes = max(1, min(parallelTracks, jobs.count))
        let outcomes = EncodeOutcomes()
        let encoder = self
        let laneJobs = jobs
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
            for index in stride(from: lane, to: laneJobs.count, by: lanes) where !outcomes.hasFailed {
                do {
                    try encoder.encode(laneJobs[index], cover: cover, lame: lame)
                    outcomes.finish(index)
                } catch {
                    outcomes.fail(index, error)
                }
            }
        }
        if let error = outcomes.firstError { throw error }

        var written = [URL]()
        var encodedFiles = [RipReport.Encoding.File]()
        var albumFolder: URL?
        var cueTracks = [CueSheet.Track]()
        var hiddenTrackFile: String?
        for job in jobs where outcomes.finished(job.index) {
            let (ripped, index, metadata, folder, file) = (job.ripped, job.index, job.metadata, job.folder, job.file)
            albumFolder = folder
            written.append(file)
            encodedFiles.append(.init(track: ripped.number, file: file.lastPathComponent))
            let tocTrack = audioTracks[index]
            if ripped.number == 0 {
                hiddenTrackFile = file.lastPathComponent
                continue
            }
            cueTracks.append(
                CueSheet.Track(
                    number: tocTrack.number, file: file.lastPathComponent,
                    sectors: disc.toc.sectorRange(of: tocTrack).count,
                    pregapSectors: disc.report?.tracks.first { $0.number == tocTrack.number }?.pregapSectors ?? 0,
                    title: metadata.title, performer: metadata.vorbisComments.first { $0.key == "ARTIST" }?.value,
                    isrc: ripped.isrc, preEmphasis: tocTrack.hasPreEmphasis, copyPermitted: tocTrack.isCopyPermitted))
            if audioTracks[index].hasPreEmphasis {
                log(
                    "  This track has pre-emphasis: the audio is as on the disc, and sounds too bright in a player"
                        + " that does not de-emphasize it. The CUE sheet marks it (FLAGS PRE).")
            }
        }
        // The album folder keeps the cover at full size, the other artwork, and the rip's report.
        if let albumFolder, let coverFile = disc.coverFile {
            let destination = albumFolder.appending(path: coverFile.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: coverFile, to: destination)
            }
        }
        if let albumFolder {
            let artwork = disc.folder.appending(path: "Artwork", directoryHint: .isDirectory)
            let destination = albumFolder.appending(path: "Artwork", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: artwork.path)
                && !FileManager.default.fileExists(atPath: destination.path)
            {
                try FileManager.default.copyItem(at: artwork, to: destination)
            }
        }
        let encoding = albumFolder.map {
            // Whole seconds, as the report's JSON keeps dates, so the record returned equals the one saved.
            RipReport.Encoding(
                date: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                format: format, encoder: encoderName(lame: lame), aac: format == .aac ? aac : nil,
                mp3: format == .mp3 ? mp3 : nil, folder: $0.path, files: encodedFiles,
                seconds: Int(Date().timeIntervalSince(encodingStarted)), replayGain: replayGainRecord)
        }
        if let albumFolder, let encoding {
            let discPart = release.media.count > 1 ? " (Disc \(medium.position))" : ""
            let destination = albumFolder.appending(path: "Rip Report\(discPart).json")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: disc.folder.appending(path: "disc.json"), to: destination)
            try encoding.save(inReportAt: destination)
            if var report = disc.report {
                report.release = report.release ?? release
                report.encoding = encoding
                try Data(report.markdown.utf8).write(to: albumFolder.appending(path: "Rip Report\(discPart).md"))
            }
            try writeCueSheet(
                cueTracks, hiddenTrackFile: hiddenTrackFile, release: release, medium: medium, toc: disc.toc,
                mcn: disc.report?.mcn, to: albumFolder, discPart: discPart)
            if let whole = replayGainRecord?.release {
                updateReleaseGain(whole, of: release, in: albumFolder, except: medium.position, library: library)
            }
        }
        return (written, encoding)
    }

    /// The program that writes the audio, for the report.
    private func encoderName(lame: URL?) -> String {
        switch format {
        case .mp3: lame.flatMap(MP3Encoder.version(of:)) ?? "LAME"
        case .wav: "Silverside \(SilversideVersion.string)"
        case .flac, .alac, .aac, .aiff: "Apple AudioToolbox"
        }
    }

    /// The CUE sheet: everything needed to burn the disc again from the files, with the tags' names.
    func writeCueSheet(
        _ tracks: [CueSheet.Track], hiddenTrackFile: String?, release: MusicBrainzRelease,
        medium: MusicBrainzRelease.Medium, toc: TOC, mcn: String?, to folder: URL, discPart: String
    ) throws {
        let sample = TrackMetadata(
            release: release, medium: medium, track: medium.tracks[0], plainPunctuation: plainPunctuation,
            segueMarks: segueMarks, compilationFolder: compilationFolder)
        let comments = sample.vorbisComments
        var sheet = CueSheet(
            title: comments.first { $0.key == "ALBUM" }?.value,
            performer: comments.first { $0.key == "ALBUMARTIST" }?.value,
            catalog: mcn ?? release.barcode.map { $0.count == 12 ? "0" + $0 : $0 }, tracks: tracks)
        sheet.hiddenTrackFile = hiddenTrackFile
        sheet.remarks = release.date.map { ["DATE \($0)"] } ?? []
        sheet.remarks.append("DISCID " + String(format: "%08X", toc.freedbDiscID))
        sheet.remarks.append("COMMENT \"\(FLACTags.vendor)\"")
        if release.media.count > 1 {
            sheet.remarks += ["DISCNUMBER \(medium.position)", "TOTALDISCS \(release.media.count)"]
        }
        let name = NameTemplate.safeComponent(sheet.title ?? "Disc") + discPart + ".cue"
        try Data(sheet.text.utf8).write(to: folder.appending(path: name))
    }

    private func write(
        _ samples: [UInt32], metadata: TrackMetadata, extra: [(key: String, value: String)], cover: EmbeddedCover?,
        to url: URL, lame: URL?
    ) throws {
        let comments = metadata.vorbisComments + extra
        switch format {
        case .flac:
            try AudioEncoder.encode(samples, format: .flac, to: url)
            try FLACTags.write(comments, cover: cover, to: url)
        case .alac, .aac:
            try AudioEncoder.encode(samples, format: format, to: url, aac: aac)
            try MP4Tags.write(comments, cover: cover, to: url)
        case .aiff:
            try AudioEncoder.encode(samples, format: .aiff, to: url)
            try ChunkTags.writeAIFF(comments, cover: cover, to: url)
        case .wav:
            try WAVFile.write(samples, to: url)
            try ChunkTags.writeWAV(comments, cover: cover, to: url)
        case .mp3:
            try MP3Encoder.encode(samples, to: url, lame: lame!, options: mp3)
            try ID3Tags.write(comments, cover: cover, to: url)
        }
    }

    /// Encodes one track: reads its WAV file, writes a partial file, checks it, and moves it
    /// into place. Runs on one of the encoding lanes.
    private func encode(_ job: Job, cover: EmbeddedCover?, lame: URL?) throws {
        try FileManager.default.createDirectory(at: job.folder, withIntermediateDirectories: true)
        let samples = try WAVFile.read(job.ripped.file)
        // Write to a partial file, and move it into place only when it is checked.
        let partial = job.folder.appending(path: ".\(UUID().uuidString).partial.\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: partial) }
        try write(samples, metadata: job.metadata, extra: job.extraComments, cover: cover, to: partial, lame: lame)
        try check(partial, against: samples, final: job.file)
        if FileManager.default.fileExists(atPath: job.file.path) { try FileManager.default.removeItem(at: job.file) }
        try FileManager.default.moveItem(at: partial, to: job.file)
        log("\(job.file.lastPathComponent)")
        trackEncoded(job.ripped.number, job.file)
    }

    /// Decodes the file: a lossless file must give the rip's samples; a lossy one, about as many.
    private func check(_ url: URL, against samples: [UInt32], final: URL) throws {
        let decoded = try AudioEncoder.decode(url)
        let matches =
            format.isLossless ? decoded == samples : abs(decoded.count - samples.count) < 4 * 1152
        guard matches else { throw EncodingError.verificationFailed(final) }
    }
}

/// Which tracks the encoding lanes finished, and the errors of those that failed.
private final class EncodeOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var done = Set<Int>()
    private var errors = [Int: any Error]()

    var hasFailed: Bool { lock.withLock { !errors.isEmpty } }
    func finish(_ index: Int) { lock.withLock { _ = done.insert(index) } }
    func finished(_ index: Int) -> Bool { lock.withLock { done.contains(index) } }
    func fail(_ index: Int, _ error: any Error) { lock.withLock { errors[index] = error } }
    /// The error of the first job that failed, in the jobs' order.
    var firstError: (any Error)? { lock.withLock { errors.min { $0.key < $1.key }?.value } }
}
