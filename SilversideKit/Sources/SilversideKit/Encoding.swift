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
public struct DiscEncoder {
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
    }

    /// The files that `encode` would write, one for each track, in order. It throws as `encode`
    /// does for a disc that cannot be encoded, but not for files that exist, so a caller can
    /// ask before it replaces them (see `overwrites`).
    public func plannedFiles(_ disc: RippedDisc, into library: URL) throws -> [URL] {
        try plan(disc, into: library).jobs.map(\.file)
    }

    private struct Job {
        var ripped: RippedDisc.Track
        var index: Int
        var metadata: TrackMetadata
        var folder: URL
        var file: URL
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
        let (release, medium, jobs) = try plan(disc, into: library)
        let lame = format == .mp3 ? MP3Encoder.lame() : nil
        if format == .mp3 && lame == nil { throw MP3Error.lameNotFound }
        // A file that exists stops the encoding before any file is written, so a half-done
        // album can be finished later.
        if !overwrites, let job = jobs.first(where: { FileManager.default.fileExists(atPath: $0.file.path) }) {
            throw EncodingError.exists(job.file)
        }

        let cover = try disc.coverFile.map { try EmbeddedCover(CoverImage(data: Data(contentsOf: $0))) }
        let audioTracks = disc.toc.audioTracks

        var written = [URL]()
        var encodedFiles = [RipReport.Encoding.File]()
        var albumFolder: URL?
        var cueTracks = [CueSheet.Track]()
        var hiddenTrackFile: String?
        for job in jobs {
            let (ripped, index, metadata, folder, file) = (job.ripped, job.index, job.metadata, job.folder, job.file)
            albumFolder = folder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let samples = try WAVFile.read(ripped.file)
            // Write to a partial file, and move it into place only when it is checked.
            let partial = folder.appending(path: ".\(UUID().uuidString).partial.\(format.fileExtension)")
            defer { try? FileManager.default.removeItem(at: partial) }
            try write(samples, metadata: metadata, cover: cover, to: partial, lame: lame)
            try check(partial, against: samples, final: file)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            try FileManager.default.moveItem(at: partial, to: file)
            written.append(file)
            encodedFiles.append(.init(track: ripped.number, file: file.lastPathComponent))
            log("\(file.lastPathComponent)")
            trackEncoded(ripped.number, file)
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
                mp3: format == .mp3 ? mp3 : nil, folder: $0.path, files: encodedFiles)
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
                cueTracks, hiddenTrackFile: hiddenTrackFile, release: release, medium: medium, disc: disc,
                to: albumFolder, discPart: discPart)
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
    private func writeCueSheet(
        _ tracks: [CueSheet.Track], hiddenTrackFile: String?, release: MusicBrainzRelease,
        medium: MusicBrainzRelease.Medium,
        disc: RippedDisc, to folder: URL, discPart: String
    ) throws {
        let sample = TrackMetadata(
            release: release, medium: medium, track: medium.tracks[0], plainPunctuation: plainPunctuation,
            segueMarks: segueMarks, compilationFolder: compilationFolder)
        let comments = sample.vorbisComments
        var sheet = CueSheet(
            title: comments.first { $0.key == "ALBUM" }?.value,
            performer: comments.first { $0.key == "ALBUMARTIST" }?.value,
            catalog: disc.report?.mcn ?? release.barcode.map { $0.count == 12 ? "0" + $0 : $0 }, tracks: tracks)
        sheet.hiddenTrackFile = hiddenTrackFile
        sheet.remarks = release.date.map { ["DATE \($0)"] } ?? []
        sheet.remarks.append("DISCID " + String(format: "%08X", disc.toc.freedbDiscID))
        sheet.remarks.append("COMMENT \"\(FLACTags.vendor)\"")
        if release.media.count > 1 {
            sheet.remarks += ["DISCNUMBER \(medium.position)", "TOTALDISCS \(release.media.count)"]
        }
        let name = NameTemplate.safeComponent(sheet.title ?? "Disc") + discPart + ".cue"
        try Data(sheet.text.utf8).write(to: folder.appending(path: name))
    }

    private func write(
        _ samples: [UInt32], metadata: TrackMetadata, cover: EmbeddedCover?, to url: URL, lame: URL?
    ) throws {
        let comments = metadata.vorbisComments
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

    /// Decodes the file: a lossless file must give the rip's samples; a lossy one, about as many.
    private func check(_ url: URL, against samples: [UInt32], final: URL) throws {
        let decoded = try AudioEncoder.decode(url)
        let matches =
            format.isLossless ? decoded == samples : abs(decoded.count - samples.count) < 4 * 1152
        guard matches else { throw EncodingError.verificationFailed(final) }
    }
}
