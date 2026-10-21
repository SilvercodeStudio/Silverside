import Foundation

/// A ripped disc in a folder: its WAV files and its disc.json, as `cdrip rip` writes it or
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
    public var release: MusicBrainzRelease?
    public var tracks: [Track]
    /// The rip's report, if the folder has one (rips before reports, in the archive, do not).
    public var report: RipReport?

    /// Deletes the files that a rip wrote in its folder (the WAV files, the suspects,
    /// disc.json, the cover, and Artwork), and the folder too if nothing else is in it.
    public func deleteRipFiles() throws {
        let manager = FileManager.default
        var files = tracks.flatMap { track in
            [track.file, folder.appending(path: TrackAudio.alternativesFileName(track: track.number))]
        }
        files += ["disc.json", "Rip Report.md", "cover.jpg", "cover.png", "Artwork", ".cdrip-rip"].map {
            folder.appending(path: $0)
        }
        for file in files where manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
        if (try? manager.contentsOfDirectory(atPath: folder.path))?.allSatisfy({ $0 == ".DS_Store" }) == true {
            try manager.removeItem(at: folder)
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
            "\(folder.path) has no MusicBrainz release. Add one with cdrip metadata -i \"\(folder.path)\"."
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
    public var aac = AACOptions()
    public var mp3 = MP3Options()
    /// Encode tracks that AccurateRip and CTDB do not prove.
    public var allowsUnverified = false
    /// Replace files that exist.
    public var overwrites = false
    /// Receives a line for each track, for people to read.
    public var log: (String) -> Void = { _ in }

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
        aac = settings.aac
        mp3 = settings.mp3
    }

    /// Encodes the disc's tracks into `library`, and returns the files written.
    @discardableResult
    public func encode(_ disc: RippedDisc, into library: URL) throws -> [URL] {
        guard let release = disc.release else { throw EncodingError.noRelease(disc.folder) }
        guard let medium = release.medium(for: disc.toc) else { throw EncodingError.unknownMedium(disc.folder) }
        if !allowsUnverified, let track = disc.tracks.first(where: { !$0.isVerified }) {
            throw EncodingError.notVerified(track: track.number)
        }
        let lame = format == .mp3 ? MP3Encoder.lame() : nil
        if format == .mp3 && lame == nil { throw MP3Error.lameNotFound }

        let cover = try disc.coverFile.map { try EmbeddedCover(CoverImage(data: Data(contentsOf: $0))) }
        let audioTracks = disc.toc.audioTracks
        var written = [URL]()
        var albumFolder: URL?
        var cueTracks = [CueSheet.Track]()
        var hiddenTrackFile: String?
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
                plainPunctuation: plainPunctuation)
            let values = metadata.nameValues
            let folder = library.appending(path: folderTemplate.name(values), directoryHint: .isDirectory)
            let file = folder.appending(path: trackTemplate.name(values) + "." + format.fileExtension)
            albumFolder = folder
            if FileManager.default.fileExists(atPath: file.path) && !overwrites { throw EncodingError.exists(file) }
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
            log("\(file.lastPathComponent)")
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
        // The album folder keeps the cover at full size, and the rip's report.
        if let albumFolder, let coverFile = disc.coverFile {
            let destination = albumFolder.appending(path: coverFile.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: coverFile, to: destination)
            }
        }
        if let albumFolder {
            let discPart = release.media.count > 1 ? " (Disc \(medium.position))" : ""
            let destination = albumFolder.appending(path: "Rip Report\(discPart).json")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: disc.folder.appending(path: "disc.json"), to: destination)
            if var report = disc.report {
                report.release = report.release ?? release
                try Data(report.markdown.utf8).write(to: albumFolder.appending(path: "Rip Report\(discPart).md"))
            }
            try writeCueSheet(
                cueTracks, hiddenTrackFile: hiddenTrackFile, release: release, medium: medium, disc: disc,
                to: albumFolder, discPart: discPart)
        }
        return written
    }

    /// The CUE sheet: everything needed to burn the disc again from the files, with the tags' names.
    private func writeCueSheet(
        _ tracks: [CueSheet.Track], hiddenTrackFile: String?, release: MusicBrainzRelease,
        medium: MusicBrainzRelease.Medium,
        disc: RippedDisc, to folder: URL, discPart: String
    ) throws {
        let sample = TrackMetadata(
            release: release, medium: medium, track: medium.tracks[0], plainPunctuation: plainPunctuation)
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
