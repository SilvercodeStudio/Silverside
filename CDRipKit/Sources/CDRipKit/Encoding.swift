import Foundation

/// A ripped disc in a folder: its WAV files and its disc.json, as `cdrip rip` writes it or
/// as the archive keeps it.
public struct RippedDisc: Sendable {
    public struct Track: Sendable {
        public var number: Int
        public var file: URL
        /// True if AccurateRip or CTDB proves the track, or the archive marks the disc complete.
        public var isVerified: Bool
        public var isrc: String?
    }

    public var folder: URL
    public var toc: TOC
    public var release: MusicBrainzRelease?
    public var tracks: [Track]

    /// Deletes the files that a rip wrote in its folder (the WAV files, the suspects,
    /// disc.json, the cover, and Artwork), and the folder too if nothing else is in it.
    public func deleteRipFiles() throws {
        let manager = FileManager.default
        var files = tracks.flatMap { track in
            [track.file, folder.appending(path: TrackAudio.alternativesFileName(track: track.number))]
        }
        files += ["disc.json", "cover.jpg", "cover.png", "Artwork", ".cdrip-rip"].map { folder.appending(path: $0) }
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
        if let report, let reportTracks = report["tracks"] as? [[String: Any]] {
            let ctdb = (report["ctdb"] as? [String: Any])?["status"] as? String
            let wholeDisc = ctdb == "verified" || ctdb == "repaired"
            tracks = reportTracks.compactMap { track in
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
        for ripped in disc.tracks {
            guard let index = audioTracks.firstIndex(where: { $0.number == ripped.number }),
                medium.tracks.indices.contains(index)
            else { throw EncodingError.unknownMedium(disc.folder) }
            let metadata = TrackMetadata(
                release: release, medium: medium, track: medium.tracks[index], isrc: ripped.isrc,
                liveShowStyle: liveShowStyle, plainPunctuation: plainPunctuation)
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
        }
        // The album folder keeps the cover at full size, and the rip's report.
        if let albumFolder, let coverFile = disc.coverFile {
            let destination = albumFolder.appending(path: coverFile.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: coverFile, to: destination)
            }
        }
        if let albumFolder {
            let name = release.media.count > 1 ? "Rip Report (Disc \(medium.position)).json" : "Rip Report.json"
            let destination = albumFolder.appending(path: name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: disc.folder.appending(path: "disc.json"), to: destination)
        }
        return written
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
        case .wav:
            try WAVFile.write(samples, to: url)
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
