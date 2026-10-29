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
    /// The file the report is in: the rip's disc.json, or an album folder's "Rip Report (Disc N).json".
    public var reportFile: URL

    /// Deletes the files that the rip wrote in its folder, as its report lists them (the WAV
    /// files, the suspects, the reports, and the artwork), and with `albumFolder`, the files
    /// that the album folder has too, byte for byte: a cover or artwork that a rip found in its
    /// folder already, from an earlier attempt, or that a change of cover wrote later, is not
    /// listed, but the library keeps it. Nothing else goes. Then the Artwork folder and the
    /// rip's folder go too, if nothing else is in them. A rip from before reports listed their
    /// files loses the files that a rip writes, by name. Nothing goes when the album folder is
    /// the rip's folder, or holds it, or is in it (with a template or a folder of the user's):
    /// the album's files would go with the rip's. Returns true if the rip's files went.
    @discardableResult
    public func deleteRipFiles(albumFolder: URL? = nil) throws -> Bool {
        let manager = FileManager.default
        if let albumFolder, Self.overlap(folder, albumFolder) { return false }
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
        // The active claim stays locked until DiscRip releases it.
        // The disc's own cover, which a later change of covers can write after the report.
        if let position = report?.discPosition {
            files += CoverFiles.extensions.map { folder.appending(path: "\(CoverFiles.discName(position)).\($0)") }
        }
        for file in files where manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
        if let albumFolder {
            for file in Self.copies(in: folder, of: albumFolder) { try manager.removeItem(at: file) }
        }
        for directory in [folder.appending(path: "Artwork"), folder] {
            let contents = try? manager.contentsOfDirectory(atPath: directory.path)
            if contents?.allSatisfy({ $0 == ".DS_Store" }) == true { try manager.removeItem(at: directory) }
        }
        return true
    }

    /// True if the two folders are one, or one is inside the other.
    static func overlap(_ first: URL, _ second: URL) -> Bool {
        if DiscEncoder.sameFile(first, second) { return true }
        let a = first.standardizedFileURL.resolvingSymlinksInPath().path
        let b = second.standardizedFileURL.resolvingSymlinksInPath().path
        return a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    /// The files in `folder` and its subfolders that `album` has at the same place, byte for
    /// byte. Hidden files, such as a rip's claim, are left alone.
    static func copies(in folder: URL, of album: URL) -> [URL] {
        let manager = FileManager.default
        guard
            let enumerator = manager.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)
        else { return [] }
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        var copies = [URL]()
        while let file = enumerator.nextObject() as? URL {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            let counterpart = album.appending(path: String(path.dropFirst(base.count + 1)))
            if manager.fileExists(atPath: counterpart.path), !DiscEncoder.sameFile(file, counterpart),
                manager.contentsEqual(atPath: path, andPath: counterpart.path)
            {
                copies.append(file)
            }
        }
        return copies
    }

    /// True if the user accepted the rip as it is (`RipReport.accepted`).
    public var isAccepted: Bool { report?.accepted != nil }

    /// True if the rip may go once every track is encoded: every track is verified, or the user
    /// accepted the rip as it is.
    public var isFinished: Bool { isAccepted || tracks.allSatisfy(\.isVerified) }

    /// The cover that the disc's files embed: its own ("cover (Disc 2).jpg", a box set's
    /// sleeve), else the folder's (cover.jpg or cover.png), if it has one.
    public var coverFile: URL? {
        CoverFiles.embedded(forDisc: report?.discPosition, in: folder)
    }

    /// The album's cover in the folder (cover.jpg or cover.png), for the album folder.
    public var albumCoverFile: URL? { CoverFiles.album(in: folder) }

    /// True for an album in the library as the source (its report is not a rip's disc.json).
    public var isAlbum: Bool { reportFile.lastPathComponent != "disc.json" }

    public init(folder: URL) throws {
        self.folder = folder
        reportFile = folder.appending(path: "disc.json")
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

extension RippedDisc {
    /// An album in the library as the source of an encoding, after its rip's WAV files are
    /// gone: the album folder's report, and the files it lists, which must be lossless. Each
    /// file must decode to the audio the rip verified (its CRC-32), or reading it throws.
    public init(albumReportAt file: URL, editsStore: ReleaseEditsStore = ReleaseEditsStore()) throws {
        let folder = file.deletingLastPathComponent()
        let report = try RipReport.read(from: file)
        guard let encoding = report.encoding else { throw EncodingError.noDiscJSON(folder) }
        guard encoding.format.isLossless else { throw EncodingError.lossySource(folder) }
        guard encoding.hdcdDecoded != true, encoding.dtsDecoded == nil else {
            throw EncodingError.alreadyDecoded(folder)
        }
        guard encoding.deEmphasizedTracks?.isEmpty != false else { throw EncodingError.deEmphasized(folder) }
        self.folder = folder
        reportFile = file
        self.report = report
        let toc = try TOC(ctdbTOCString: report.toc)
        self.toc = toc
        let edits = report.release.map { MetadataEdits.current(forReportAt: file, release: $0, store: editsStore) }
        self.edits = edits
        release = report.release.map { edits?.applied(to: $0, toc: toc) ?? $0 }
        let tracks: [Track] = report.tracks.compactMap { track in
            encoding.file(ofTrack: track.number).map {
                Track(
                    number: track.number, file: folder.appending(path: $0),
                    isVerified: report.isVerified || track.accurateRip == .accurate
                        || track.accurateRip == .otherPressings || (track.ctdbConfidence ?? 0) > 0,
                    isrc: track.isrc)
            }
        }
        let hidden = report.hiddenTrack.flatMap { hidden in
            encoding.file(ofTrack: 0).map {
                Track(number: 0, file: folder.appending(path: $0), isVerified: hidden.readsAgree, isrc: nil)
            }
        }
        self.tracks = (hidden.map { [$0] } ?? []) + tracks
    }

    /// A track's ripped audio: its WAV file, or a lossless encoded file, which must decode to
    /// the CRC-32 the report has for the track. A report too old to have the CRC-32 cannot
    /// check the file, and its audio is taken as it is.
    func audio(of track: Track) throws -> [UInt32] {
        let samples =
            try track.file.pathExtension.lowercased() == "wav"
            ? WAVFile.read(track.file) : AudioEncoder.decode(track.file)
        let expectedFrames =
            track.number == 0
            ? report?.hiddenTrack.map { $0.sectors * CDDA.samplesPerSector }
            : toc.track(track.number).map { toc.sectorRange(of: $0).count * CDDA.samplesPerSector }
        if let expectedFrames, samples.count != expectedFrames { throw EncodingError.sourceChanged(track.file) }
        let expected =
            track.number == 0
            ? report?.hiddenTrack?.crc32
            : report?.tracks.first(where: { $0.number == track.number })?.crc32
        if let expected,
            CRC32.hex(CRC32.checksum(of: samples[...])) != expected
        {
            throw EncodingError.sourceChanged(track.file)
        }
        return samples
    }
}

public enum EncodingError: Error, Equatable, CustomStringConvertible {
    case noDiscJSON(URL)
    case noRelease(URL)
    case unknownMedium(URL)
    case notVerified(track: Int)
    case exists(URL)
    case verificationFailed(URL)
    case lossySource(URL)
    case alreadyDecoded(URL)
    case deEmphasized(URL)
    case sourceChanged(URL)
    case duplicateDestination(URL)
    /// No disc of the release has the rip's TOC.
    case notOnRelease(URL)

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
        case .lossySource(let folder):
            "\(folder.path) holds lossy files, which no longer have the ripped audio to encode from."
        case .alreadyDecoded(let folder):
            "\(folder.path) holds a decode (HDCD or DTS), which is no longer the ripped audio to encode from."
        case .deEmphasized(let folder):
            "\(folder.path) holds de-emphasized tracks, which are no longer the ripped audio to encode from."
        case .duplicateDestination(let file):
            "Several tracks would write to \(file.path). Choose a template with unique track names."
        case .sourceChanged(let file): "\(file.path) no longer decodes to the audio that was ripped and verified."
        case .notOnRelease(let folder): "No disc of that release is the disc that \(folder.path) holds."
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
    /// Decode a disc whose HDCD codes ask for peak extend or a gain adjustment into 20-bit (24-bit for AIFF and WAV)
    /// files, tagged HDCD=decoded. A disc whose codes ask for nothing is encoded as it is.
    public var decodesHDCD = false
    /// Take the pre-emphasis out of the tracks whose control bits ask for it (in the TOC or the
    /// Q subchannel, as the rip's report has them), as a CD player does: 20-bit files (24-bit
    /// for AIFF and WAV), tagged DE_EMPHASIZED=yes. Other tracks are encoded as they are. When
    /// false, those tracks are tagged PRE_EMPHASIS=yes.
    public var deEmphasizes = true
    /// Decode the tracks that hold a DTS stream (a DTS-CD) with ffmpeg, into surround files
    /// tagged DTS=decoded (see `DTSDecoder`). When false, they keep the stream as the disc has
    /// it, which only a lossless format can. Other tracks are encoded as they are.
    public var decodesDTS = false
    /// The ffmpeg program for `decodesDTS`; nil finds it (`FFmpeg.program()`).
    public var ffmpeg: URL?
    /// Added to the album's title in names and tags, as " (HDCD)" for a decoded copy beside
    /// the album: the copy gets a folder of its own, and players list it apart.
    public var albumSuffix: String?
    /// Where disc images go (see `writeImage`), or nil for none.
    public var images: URL?
    /// How many tracks encode at once. Each track in flight holds its audio twice (the rip and
    /// the decoded check), about 300 MB for a long track (twice that for an HDCD decode, which
    /// uses half as many lanes), so the default stays at four even on a Mac with many cores:
    /// half the cores, at least two, at most four.
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
        decodesHDCD = settings.hdcd == .decode
        deEmphasizes = settings.preEmphasis != .keep
        images = settings.writeImages ? settings.imagesURL : nil
    }

    /// The files that `encode` would write, one for each track, in order. It throws as `encode`
    /// does for a disc that cannot be encoded, but not for files that exist, so a caller can
    /// ask before it replaces them (see `overwrites`).
    public func plannedFiles(_ disc: RippedDisc, into library: URL) throws -> [URL] {
        let (release, medium, jobs) = try plan(disc, into: library)
        let discPart = release.media.count > 1 ? " (Disc \(medium.position))" : ""
        let data = jobs.first.map { dataTrackCopies(of: disc, into: $0.folder, discPart: discPart) } ?? []
        // A data track's image, and the folder its files go into.
        return jobs.map(\.file)
            + data.filter { !Self.sameFile($0.source, $0.target) }.flatMap {
                [$0.target, Self.filesFolder(of: $0.target)]
            }
    }

    /// The folder beside a data track's image that holds its files: "Data track" for "Data track.iso".
    static func filesFolder(of image: URL) -> URL {
        image.deletingPathExtension().appending(path: "", directoryHint: .isDirectory)
    }

    /// Copies the data tracks' images into the album folder, each with a folder of the files on
    /// it, and returns the images' names there.
    func placeDataTracks(
        _ copies: [(track: RipReport.DataTrack, source: URL, target: URL, base: String)]
    ) throws -> [String] {
        var names = [String]()
        for (track, source, target, base) in copies {
            let albumFolder = target.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: source.path), !Self.sameFile(source, target) {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: source, to: target)
                log("\(target.lastPathComponent)")
            }
            guard FileManager.default.fileExists(atPath: target.path) else { continue }
            if !Self.sameFile(source, target)
                || !FileManager.default.fileExists(atPath: Self.filesFolder(of: target).path)
            {
                let files = albumFolder.appending(path: base, directoryHint: .isDirectory)
                try? FileManager.default.removeItem(at: files)
                if let reader = try? ISO9660Reader(image: target, startLBA: track.startLBA ?? 0),
                    let extracted = try? reader.extract(to: files)
                {
                    log("\(base)/: \(extracted.files) files from its file system")
                }
            }
            names.append(base + ".iso")
        }
        return names
    }

    /// The files in the album folder that Save Data Track of track `number` would replace,
    /// though the rip's encoding did not put them there: another edition's image, or a file of
    /// the user's in the folder of an image's files. Save Data Track replaces them only when
    /// `overwrites` is set.
    public func dataTrackConflicts(_ number: Int, reportAt file: URL) throws -> [URL] {
        let report = try RipReport.read(from: file)
        let album: URL
        if file.lastPathComponent == "disc.json" {
            guard let folder = report.encoding?.folder, FileManager.default.fileExists(atPath: folder) else {
                return []
            }
            album = URL(filePath: folder, directoryHint: .isDirectory)
        } else {
            album = file.deletingLastPathComponent()
        }
        let numbers = Set((report.dataTracks ?? []).map(\.number) + [number]).sorted()
        let discPart = try Self.discPart(of: report)
        let owned = Set(report.encoding?.dataTrackFiles ?? [])
        var conflicts = [URL]()
        for track in numbers {
            let base = "Data track" + (numbers.count > 1 ? " \(track)" : "") + discPart
            guard !owned.contains(base + ".iso") else { continue }
            let image = album.appending(path: base + ".iso")
            conflicts += [image, Self.filesFolder(of: image)].filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        return conflicts
    }

    /// " (Disc 2)" for a disc of a release with several, as the album folder's names have it.
    static func discPart(of report: RipReport) throws -> String {
        let toc = try TOC(ctdbTOCString: report.toc)
        guard (report.release?.media.count ?? 1) > 1, let medium = report.release?.medium(for: toc) else { return "" }
        return " (Disc \(medium.position))"
    }

    /// Save Data Track: reads a data track that a rip did not save (`RipReport.dataTrackFailures`,
    /// or one skipped) from the disc in `drive`, which must be the rip's disc. A rip's folder
    /// gets it as `Track NN.iso`; when the rip was encoded, the album folder gets it too, with
    /// the files on it, as an encoding puts it there. A report kept in the library gets it in
    /// its album folder. Each report records it. Throws `EncodingError.exists`, before it reads
    /// anything, when that would replace files the rip does not own (`dataTrackConflicts`)
    /// and `overwrites` is not set.
    public func saveDataTrack(
        _ number: Int, reportAt file: URL, drive: any CDDrive, stop: StopToken? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws -> RipReport.DataTrack {
        let report = try RipReport.read(from: file)
        let toc = try TOC(ctdbTOCString: report.toc)
        guard try drive.readTOC().ctdbTOCString == report.toc else { throw DataTrackError.otherDisc }
        guard let track = toc.tracks.first(where: { $0.number == number && $0.kind == .data }) else {
            throw DataTrackError.notData(track: number)
        }
        if !overwrites, let conflict = try dataTrackConflicts(number, reportAt: file).first {
            throw EncodingError.exists(conflict)
        }
        let folder = file.deletingLastPathComponent()
        let isRipFolder = file.lastPathComponent == "disc.json"
        let discPart = try Self.discPart(of: report)
        func record(_ saved: RipReport.DataTrack, in report: inout RipReport) {
            report.dataTracks = ((report.dataTracks ?? []).filter { $0.number != number } + [saved])
                .sorted { $0.number < $1.number }
            report.dataTrackFailures = report.dataTrackFailures?.filter { $0.number != number }
            if report.dataTrackFailures?.isEmpty == true { report.dataTrackFailures = nil }
        }
        func base(count: Int) -> String { "Data track" + (count > 1 ? " \(number)" : "") + discPart }

        if isRipFolder {
            try RipFolder.claimExactly(folder, toc: toc)
            defer { RipFolder.release(folder) }
            let name = RipReport.DataTrack.fileName(track: number)
            let saved = try DataTrackReader.read(
                track, in: toc, drive: drive, to: folder.appending(path: name), stop: stop, progress: progress)
            var updated = try RipReport.update(reportAt: file) { report in
                record(saved, in: &report)
                report.files = Array(Set((report.files ?? []) + [name])).sorted()
            }
            try Data(updated.markdown.utf8).write(to: folder.appending(path: "Rip Report.md"))
            // An encoded rip's album gets it as an encoding would have put it there.
            if let encoding = updated.encoding, FileManager.default.fileExists(atPath: encoding.folder) {
                let album = URL(filePath: encoding.folder, directoryHint: .isDirectory)
                let copies = dataTrackCopies(of: try RippedDisc(folder: folder), into: album, discPart: discPart)
                let names = try placeDataTracks(copies)
                updated = try RipReport.update(reportAt: file) {
                    $0.encoding?.dataTrackFiles = names.isEmpty ? nil : names
                }
                let albumReport = album.appending(path: "Rip Report\(discPart).json")
                if FileManager.default.fileExists(atPath: albumReport.path) {
                    let shown = try RipReport.update(reportAt: albumReport) { report in
                        record(saved, in: &report)
                        report.encoding?.dataTrackFiles = names.isEmpty ? nil : names
                    }
                    try Data(shown.markdown.utf8).write(to: album.appending(path: "Rip Report\(discPart).md"))
                }
            }
            return saved
        }
        // A report in the library: the image goes into its album folder, as an encoding names it.
        let count = Set((report.dataTracks ?? []).map(\.number) + [number]).count
        let target = folder.appending(path: base(count: count) + ".iso")
        var saved = try DataTrackReader.read(track, in: toc, drive: drive, to: target, stop: stop, progress: progress)
        saved.file = target.lastPathComponent
        _ = try placeDataTracks([(saved, target, target, base(count: count))])
        let shown = try RipReport.update(reportAt: file) { report in
            record(saved, in: &report)
            let names = (report.encoding?.dataTrackFiles ?? []).filter { $0 != target.lastPathComponent }
            report.encoding?.dataTrackFiles = names + [target.lastPathComponent]
        }
        try Data(shown.markdown.utf8).write(to: folder.appending(path: "Rip Report\(discPart).md"))
        return saved
    }

    /// The data tracks' ISO images (an Enhanced CD's extras) to copy into the album folder:
    /// from the rip's `Track NN.iso`, or, when an album is the source, from its own images. A
    /// decoded copy beside the album gets none.
    func dataTrackCopies(
        of disc: RippedDisc, into folder: URL, discPart: String
    ) -> [(track: RipReport.DataTrack, source: URL, target: URL, base: String)] {
        guard albumSuffix == nil, let saved = disc.report?.dataTracks else { return [] }
        let albumFiles = disc.isAlbum ? disc.report?.encoding?.dataTrackFiles ?? [] : []
        return saved.enumerated().map { index, track in
            let base = "Data track" + (saved.count > 1 ? " \(track.number)" : "") + discPart
            let source =
                disc.isAlbum
                ? disc.folder.appending(path: albumFiles.indices.contains(index) ? albumFiles[index] : base + ".iso")
                : disc.folder.appending(path: track.file)
            return (track, source, folder.appending(path: base + ".iso"), base)
        }
    }

    private struct Job: Sendable {
        var ripped: RippedDisc.Track
        var index: Int
        var metadata: TrackMetadata
        var folder: URL
        var file: URL
        /// True if the track has pre-emphasis, from its control bits (track 1's, for a hidden track).
        var hasPreEmphasis = false
        /// True if the encoding takes the pre-emphasis out.
        var deEmphasizes = false
        /// The track before it on the disc, if this encoding has it: its end settles the HDCD
        /// decoder, and the de-emphasis filter when `previousDeEmphasizes`.
        var previous: RippedDisc.Track?
        var previousDeEmphasizes = false
        /// The track after it on the disc, if this encoding has it: a DTS stream's frames run
        /// across the tracks' starts.
        var next: RippedDisc.Track?
        /// True if the track holds a DTS stream.
        var isDTS = false
        /// Tags beyond the metadata's: the ReplayGain values, once every track is measured.
        var extraComments: [(key: String, value: String)] = []
    }

    /// Every track's names, before any file is written.
    private func plan(_ disc: RippedDisc, into library: URL) throws -> (
        release: MusicBrainzRelease, medium: MusicBrainzRelease.Medium, jobs: [Job]
    ) {
        guard var release = disc.release else { throw EncodingError.noRelease(disc.folder) }
        if let albumSuffix { release.title += albumSuffix }
        guard let medium = release.medium(for: disc.toc) else { throw EncodingError.unknownMedium(disc.folder) }
        if !allowsUnverified, !disc.isAccepted, let track = disc.tracks.first(where: { !$0.isVerified }) {
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
        try Self.checkUniqueDestinations(jobs.map(\.file))
        // Pre-emphasis, from the report's flags (the TOC's or the Q subchannel's). The audio
        // before track 1 follows track 1's flag.
        let emphasized = Set(disc.report?.tracks.filter(\.preEmphasis).map(\.number) ?? [])
        for position in jobs.indices {
            let number = jobs[position].ripped.number
            jobs[position].hasPreEmphasis = emphasized.contains(number == 0 ? audioTracks.first?.number ?? 1 : number)
            jobs[position].deEmphasizes = deEmphasizes && jobs[position].hasPreEmphasis
        }
        // The track before each one on the disc, when it is in this encoding too.
        for position in jobs.indices.dropFirst() {
            let (before, number) = (jobs[position - 1].ripped.number, jobs[position].ripped.number)
            guard before == 0 || before == number - 1 else { continue }
            jobs[position].previous = jobs[position - 1].ripped
            jobs[position].previousDeEmphasizes = jobs[position - 1].deEmphasizes
            jobs[position - 1].next = jobs[position].ripped
        }
        return (release, medium, jobs)
    }

    /// Conservative across case-sensitive and case-insensitive libraries, including canonical Unicode aliases.
    static func checkUniqueDestinations(_ files: [URL]) throws {
        var seen = Set<String>()
        for file in files {
            let key = file.standardizedFileURL.resolvingSymlinksInPath().path
                .precomposedStringWithCanonicalMapping.folding(
                    options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard seen.insert(key).inserted else { throw EncodingError.duplicateDestination(file) }
        }
    }

    /// The same destination through a symlink, or the same existing file through another
    /// spelling (including case aliases on case-insensitive volumes and hard links).
    static func sameFile(_ first: URL, _ second: URL) -> Bool {
        let first = first.standardizedFileURL.resolvingSymlinksInPath()
        let second = second.standardizedFileURL.resolvingSymlinksInPath()
        if first == second { return true }
        guard
            let firstID = (try? first.resourceValues(forKeys: [.fileResourceIdentifierKey]))?
                .fileResourceIdentifier as? NSObject,
            let secondID = (try? second.resourceValues(forKeys: [.fileResourceIdentifierKey]))?
                .fileResourceIdentifier as? NSObject
        else { return false }
        return firstID.isEqual(secondID)
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
        // A DTS-CD's tracks: decoded, or kept as the stream, which only a lossless format keeps.
        // They have no pre-emphasis or HDCD to take out: their bits are not PCM.
        let dtsTracks = try dtsTracks(of: disc)
        let dtsDecoder: DTSDecoder?
        if !dtsTracks.isEmpty && decodesDTS {
            guard AudioEncoder.holdsSurround(format) else { throw DTSError.noSurround(format) }
            guard let program = ffmpeg ?? FFmpeg.program() else { throw DTSError.ffmpegNotFound }
            dtsDecoder = DTSDecoder(ffmpeg: program)
        } else {
            dtsDecoder = nil
        }
        if !dtsTracks.isEmpty {
            if dtsDecoder == nil && !format.isLossless { throw DTSError.lossyStream(format) }
            for index in jobs.indices where dtsTracks.contains(jobs[index].ripped.number) {
                jobs[index].isDTS = true
                jobs[index].hasPreEmphasis = false
                jobs[index].deEmphasizes = false
            }
            for index in jobs.indices.dropFirst() where jobs[index].previous != nil {
                jobs[index].previousDeEmphasizes = jobs[index - 1].deEmphasizes
            }
        }
        let discPart = release.media.count > 1 ? " (Disc \(medium.position))" : ""
        let dataTrackCopies = jobs.first.map { dataTrackCopies(of: disc, into: $0.folder, discPart: discPart) } ?? []
        // A file that exists stops the encoding before any file is written, so a half-done
        // album can be finished later. So does a data track's image, which is not the source.
        if !overwrites, let job = jobs.first(where: { FileManager.default.fileExists(atPath: $0.file.path) }) {
            throw EncodingError.exists(job.file)
        }
        // A data track's image, or the folder of its files, which would be replaced as a whole.
        if !overwrites,
            let existing = dataTrackCopies.filter({ !Self.sameFile($0.source, $0.target) })
                .flatMap({ [$0.target, Self.filesFolder(of: $0.target)] })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        {
            throw EncodingError.exists(existing)
        }

        let cover = try disc.coverFile.map { try EmbeddedCover(CoverImage(data: Data(contentsOf: $0))) }
        let audioTracks = disc.toc.audioTracks
        // A disc whose codes ask for nothing is decoded too when another disc of the release in
        // the album folder holds the decode. Its decode is its audio 6.02 dB lower, nothing lost,
        // and without it the discs of one album would play 6 dB apart.
        let followsDecodedDiscs =
            release.cdPositions.count > 1
            && jobs.first.map { job in
                Self.albumReports(of: release, in: job.folder).contains {
                    $0.report.discPosition != medium.position && $0.report.encoding?.hdcdDecoded == true
                }
            } == true
        let hdcd =
            !dtsTracks.isEmpty ? nil : try decodesHDCD || followsDecodedDiscs ? hdcdStatus(of: disc) : disc.report?.hdcd
        let decodes =
            (decodesHDCD && hdcd == .featuresUsed)
            || (followsDecodedDiscs && (hdcd == .codesOnly || hdcd == .featuresUsed))
        if decodes && hdcd == .codesOnly {
            log("HDCD: the codes ask for nothing, but the other discs of the release hold the decode.")
        }
        if decodes {
            log(
                "HDCD: decoding the codes"
                    + (format.isLossless ? " into \(format.wideBits)-bit files" : "") + ", tagged HDCD=decoded.")
        }
        for index in jobs.indices {
            jobs[index].extraComments =
                HDCDStatus.tags(hdcd, decoded: decodes)
                + PreEmphasis.tags(hasPreEmphasis: jobs[index].hasPreEmphasis, deEmphasized: jobs[index].deEmphasizes)
                + (jobs[index].isDTS ? DTSStream.tags(decoded: dtsDecoder != nil) : [])
        }
        if !dtsTracks.isEmpty {
            let which =
                dtsTracks.count == disc.toc.audioTracks.count
                ? "the tracks" : "tracks " + RipReport.list(dtsTracks.sorted())
            log(
                dtsDecoder != nil
                    ? "DTS: decoding the stream of \(which) with ffmpeg into surround \(format.name) files, tagged DTS=decoded."
                    : "DTS: \(which) hold a DTS stream; the files keep it as the disc has it, for a DTS decoder.")
        }
        let deEmphasized = jobs.filter(\.deEmphasizes).map(\.ripped.number)
        if !deEmphasized.isEmpty {
            log(
                "Pre-emphasis: de-emphasizing " + (deEmphasized.count == 1 ? "track " : "tracks ")
                    + RipReport.list(deEmphasized)
                    + (format.isLossless ? " into \(format.wideBits)-bit files" : "") + ", tagged DE_EMPHASIZED=yes.")
        }

        // A track in flight holds its audio; an HDCD decode's or de-emphasis's values are twice
        // as wide, so half as many tracks go at once.
        let lanes = max(
            1, decodes || !deEmphasized.isEmpty || dtsDecoder != nil ? parallelTracks / 2 : parallelTracks)

        // ReplayGain needs every track's loudness before the first tag is written: the album's
        // gain is one gating over all of them. The tracks are measured from their WAV files,
        // as many at a time as they encode.
        // For the last disc of a multi-disc release into the album folder, the album is the whole release.
        var replayGainRecord: RipReport.Encoding.ReplayGainRecord?
        // A DTS stream is not audio to measure; its decode is.
        if replayGain && !dtsTracks.isEmpty && dtsDecoder == nil {
            log("ReplayGain: none, as the DTS stream is not audio a player plays.")
        }
        if replayGain && (dtsTracks.isEmpty || dtsDecoder != nil) {
            let measured = CTDB.parallelMap(over: jobs, lanes: lanes) {
                job -> Result<ReplayGain.Analysis, any Error>? in
                Result {
                    switch try audio(of: job, in: disc, decodes: decodes, dts: dtsDecoder) {
                    case .pcm(let pcm): ReplayGain.analyze(pcm)
                    case .surround(let surround): ReplayGain.analyze(surround)
                    }
                }
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
                jobs[index].extraComments += ReplayGain.tags(track: track, album: whole?.values ?? album)
                if let track { tracks.append(.init(track: jobs[index].ripped.number, values: track)) }
            }
            replayGainRecord = .init(
                album: album, tracks: tracks, histogram: histogram, release: whole?.values, releaseDiscs: whole?.discs)
        }

        // An album encoded from its own files into its own folder replaces its source, in any
        // format, WAV too; so does any encoding that would write over a source file. Then
        // every track is written and checked before the first original goes, so a failure
        // leaves the album as it was, and a later try can read it again; and no track reads
        // the track before (for the HDCD decoder or the de-emphasis filter) after it changed.
        let sources = disc.tracks.map { $0.file.standardizedFileURL.resolvingSymlinksInPath() }
        let replacesSource =
            (disc.isAlbum && jobs.first.map { Self.sameFile($0.folder, disc.folder) } == true)
            || jobs.contains { job in sources.contains { Self.sameFile(job.file, $0) } }

        // Each lane takes every n-th job, in order, so the lanes keep in step and no more than
        // that many tracks are in memory. A failure stops the lanes after the tracks under
        // way; the files written stay, as they did when the tracks went one by one, except
        // when they would replace the source.
        let encodingLanes = min(lanes, max(1, jobs.count))
        let outcomes = EncodeOutcomes(log: log)
        let encoder = self
        let laneJobs = jobs
        DispatchQueue.concurrentPerform(iterations: encodingLanes) { lane in
            for index in stride(from: lane, to: laneJobs.count, by: encodingLanes) where !outcomes.hasFailed {
                do {
                    let staged = try encoder.encode(
                        laneJobs[index], of: disc, decodes: decodes, dts: dtsDecoder, cover: cover, lame: lame,
                        staging: replacesSource, outcomes: outcomes)
                    // A staged file is named once it replaces its source, below.
                    outcomes.finish(
                        index, staged: staged, line: staged == nil ? laneJobs[index].file.lastPathComponent : nil)
                } catch {
                    outcomes.fail(index, error)
                }
            }
        }
        outcomes.logTheRest()
        defer {
            for staged in outcomes.staged.values { try? FileManager.default.removeItem(at: staged) }
        }
        if let error = outcomes.firstError {
            throw error
        }

        var written = [URL]()
        var encodedFiles = [RipReport.Encoding.File]()
        var albumFolder: URL?
        var cueTracks = [CueSheet.Track]()
        var hiddenTrackFile: String?
        for (position, job) in jobs.enumerated() where outcomes.finished(position) {
            let (ripped, index, metadata, folder, file) = (job.ripped, job.index, job.metadata, job.folder, job.file)
            albumFolder = folder
            written.append(file)
            encodedFiles.append(.init(track: ripped.number, file: file.lastPathComponent))
            let tocTrack = audioTracks[index]
            if ripped.number == 0 {
                hiddenTrackFile = file.lastPathComponent
                continue
            }
            // The report's flags include the Q subchannel's, which can set a flag that the TOC does not.
            let reported = disc.report?.tracks.first { $0.number == tocTrack.number }
            let preEmphasis = tocTrack.hasPreEmphasis || reported?.preEmphasis == true
            cueTracks.append(
                CueSheet.Track(
                    number: tocTrack.number, file: file.lastPathComponent,
                    sectors: disc.toc.sectorRange(of: tocTrack).count, pregapSectors: reported?.pregapSectors ?? 0,
                    indexes: reported?.indexes ?? [],
                    title: metadata.title, performer: metadata.vorbisComments.first { $0.key == "ARTIST" }?.value,
                    isrc: ripped.isrc, preEmphasis: preEmphasis,
                    copyPermitted: tocTrack.isCopyPermitted || reported?.isCopyPermitted == true))
            if preEmphasis && !job.deEmphasizes {
                log(
                    "  This track has pre-emphasis: the audio is as on the disc, and sounds too bright in a player"
                        + " that does not de-emphasize it. It is tagged PRE_EMPHASIS=yes, and the CUE sheet marks it"
                        + " (FLAGS PRE).")
            }
        }
        func writeDiscImage() throws -> URL? {
            guard let images, albumSuffix == nil, let albumFolder else { return nil }
            let sheet = cueSheet(
                cueTracks, hiddenTrackFile: nil, release: release, medium: medium, toc: disc.toc,
                mcn: disc.report?.mcn)
            return try writeImage(
                of: disc, sheet: sheet, name: NameTemplate.safeComponent(sheet.title ?? "Disc") + discPart,
                folder: imageFolder(for: albumFolder, library: library, images: images),
                tags: imageTags(sheet: sheet, release: release, medium: medium, hdcd: disc.report?.hdcd),
                cover: cover)
        }
        // An image needs the original PCM. If its write fails, leave the album and its report
        // untouched, so the user can fix the destination and retry from the same sources.
        let preparedImage = try replacesSource ? writeDiscImage() : nil

        // Keep the originals during the swap so that a failed move can be undone. The image
        // is already checked. An album keeps only the new files; a rip keeps untouched sources.
        var originals = sources
        let aside = disc.folder.appending(
            path: ".silverside-originals-\(UUID().uuidString)", directoryHint: .isDirectory)
        if replacesSource {
            try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
            var placed = [URL]()
            do {
                for index in originals.indices
                where disc.isAlbum || jobs.contains(where: { Self.sameFile($0.file, sources[index]) }) {
                    let moved = aside.appending(path: "\(index)-\(originals[index].lastPathComponent)")
                    try FileManager.default.moveItem(at: originals[index], to: moved)
                    originals[index] = moved
                }
                // Outcomes are kept by the job's place in `jobs`, not by `job.index` (its audio
                // track's index), which differs for a hidden track and for a rip of some tracks only.
                for (position, job) in jobs.enumerated() {
                    guard let staged = outcomes.staged[position] else { continue }
                    if FileManager.default.fileExists(atPath: job.file.path) {
                        try FileManager.default.removeItem(at: job.file)
                    }
                    try FileManager.default.moveItem(at: staged, to: job.file)
                    placed.append(job.file)
                }
            } catch {
                // The originals go back, so that a later try can read the album again.
                for file in placed { try? FileManager.default.removeItem(at: file) }
                for (index, file) in originals.enumerated() where file != sources[index] {
                    try? FileManager.default.moveItem(at: file, to: sources[index])
                }
                // If a restore failed, leave its backup available for recovery.
                _ = rmdir(aside.path)
                throw error
            }
            for job in jobs where placed.contains(job.file) {
                log("\(job.file.lastPathComponent)")
                trackEncoded(job.ripped.number, job.file)
            }
        }
        defer { if replacesSource { try? FileManager.default.removeItem(at: aside) } }

        // The album folder keeps the cover at full size, the other artwork, and the rip's report.
        // A disc with its own cover (a box set's sleeve) keeps it there too, by its number.
        if let albumFolder, let coverFile = disc.albumCoverFile, CoverFiles.album(in: albumFolder) == nil {
            try FileManager.default.copyItem(
                at: coverFile, to: albumFolder.appending(path: coverFile.lastPathComponent))
        }
        if let albumFolder, !Self.sameFile(albumFolder, disc.folder) {
            try CoverFiles.removeDisc(medium.position, in: albumFolder)
            if let own = CoverFiles.disc(medium.position, in: disc.folder) {
                try FileManager.default.copyItem(at: own, to: albumFolder.appending(path: own.lastPathComponent))
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
        // The data tracks' ISO images (an Enhanced CD's extras) go into the album folder, beside
        // the audio, with the files of their ISO 9660 file systems in a folder of the same name:
        // the image alone does not open, as its file system counts from the disc's start.
        let dataTrackFiles = albumFolder != nil ? try placeDataTracks(dataTrackCopies) : []
        let encoding = albumFolder.map {
            // Whole seconds, as the report's JSON keeps dates, so the record returned equals the one saved.
            RipReport.Encoding(
                date: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                format: format, encoder: encoderName(lame: lame, dts: dtsDecoder), aac: format == .aac ? aac : nil,
                mp3: format == .mp3 ? mp3 : nil, folder: $0.path, files: encodedFiles,
                seconds: Int(Date().timeIntervalSince(encodingStarted)), replayGain: replayGainRecord)
        }.map {
            var encoding = $0
            encoding.hdcdDecoded = decodes ? true : nil
            encoding.dtsDecoded = dtsDecoder != nil ? outcomes.surroundLayout : nil
            encoding.deEmphasizedTracks = deEmphasized.isEmpty ? nil : deEmphasized
            encoding.albumSuffix = albumSuffix
            encoding.dataTrackFiles = dataTrackFiles.isEmpty ? nil : dataTrackFiles
            return encoding
        }
        if let albumFolder, let encoding {
            let destination = albumFolder.appending(path: "Rip Report\(discPart).json")
            // An album encoded again from its own files keeps its report, with the new encoding.
            if !Self.sameFile(destination, disc.reportFile) {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: disc.reportFile, to: destination)
            }
            try encoding.save(inReportAt: destination)
            // A rip from before Silverside looked for DTS: its album's report says what was found,
            // so that an update of the library keeps the tags.
            if disc.report != nil, disc.report?.dts == nil {
                _ = try? RipReport.update(reportAt: destination) { Self.recordDTS(dtsTracks, in: &$0) }
            }
            if var report = disc.report {
                if report.dts == nil { Self.recordDTS(dtsTracks, in: &report) }
                report.release = release
                report.encoding = encoding
                try Data(report.markdown.utf8).write(to: albumFolder.appending(path: "Rip Report\(discPart).md"))
            }
            let listeningTracks = cueTracks.map { track in
                var track = track
                if deEmphasized.contains(track.number) { track.preEmphasis = false }
                return track
            }
            try writeCueSheet(
                listeningTracks, hiddenTrackFile: hiddenTrackFile, release: release, medium: medium, toc: disc.toc,
                mcn: disc.report?.mcn, to: albumFolder, discPart: discPart)
            if let whole = replayGainRecord?.release {
                updateReleaseGain(whole, of: release, in: albumFolder, except: medium.position, library: library)
            }
            // With separate sources, image failure can leave the finished album in place:
            // those sources are still available for retry. Replacements prepared the image first.
            if let image = try replacesSource ? preparedImage : writeDiscImage() {
                var record = encoding
                record.image = image.path
                try record.save(inReportAt: destination)
                return (written, record)
            }
        }
        return (written, encoding)
    }

    /// The program that writes the audio, for the report; with the DTS decoder, if it ran.
    private func encoderName(lame: URL?, dts: DTSDecoder?) -> String {
        let writer =
            switch format {
            case .mp3: lame.flatMap(MP3Encoder.version(of:)) ?? "LAME"
            case .wav: "Silverside \(SilversideVersion.string)"
            case .flac, .alac, .aac, .aiff: "Apple AudioToolbox"
            }
        guard let dts else { return writer }
        return (FFmpeg.version(of: dts.ffmpeg) ?? "FFmpeg") + " (DTS), " + writer
    }

    /// The CUE sheet: everything needed to burn the disc again from the files, with the tags' names.
    func writeCueSheet(
        _ tracks: [CueSheet.Track], hiddenTrackFile: String?, release: MusicBrainzRelease,
        medium: MusicBrainzRelease.Medium, toc: TOC, mcn: String?, to folder: URL, discPart: String
    ) throws {
        let sheet = cueSheet(
            tracks, hiddenTrackFile: hiddenTrackFile, release: release, medium: medium, toc: toc, mcn: mcn)
        let name = NameTemplate.safeComponent(sheet.title ?? "Disc") + discPart + ".cue"
        try Data(sheet.text.utf8).write(to: folder.appending(path: name))
    }

    /// The CUE sheet of the tracks' files, with the album's names, the MCN, and remarks.
    func cueSheet(
        _ tracks: [CueSheet.Track], hiddenTrackFile: String?, release: MusicBrainzRelease,
        medium: MusicBrainzRelease.Medium, toc: TOC, mcn: String?
    ) -> CueSheet {
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
        return sheet
    }

    private func write(
        _ audio: JobAudio, metadata: TrackMetadata, extra: [(key: String, value: String)], cover: EmbeddedCover?,
        to url: URL, lame: URL?
    ) throws {
        let comments = metadata.vorbisComments + extra
        guard case .pcm(let pcm) = audio else {
            guard case .surround(let surround) = audio else { return }
            try AudioEncoder.encode(surround, format: format, to: url, aac: aac)
            switch format {
            case .flac: try FLACTags.write(comments, cover: cover, to: url)
            case .alac, .aac: try MP4Tags.write(comments, cover: cover, to: url)
            case .aiff: try ChunkTags.writeAIFF(comments, cover: cover, to: url)
            case .wav, .mp3: throw DTSError.noSurround(format)
            }
            return
        }
        switch format {
        case .flac:
            try AudioEncoder.encode(pcm, format: .flac, to: url)
            try FLACTags.write(comments, cover: cover, to: url)
        case .alac, .aac:
            try AudioEncoder.encode(pcm, format: format, to: url, aac: aac)
            try MP4Tags.write(comments, cover: cover, to: url)
        case .aiff:
            try AudioEncoder.encode(pcm, format: .aiff, to: url)
            try ChunkTags.writeAIFF(comments, cover: cover, to: url)
        case .wav:
            try WAVFile.write(pcm, to: url)
            try ChunkTags.writeWAV(comments, cover: cover, to: url)
        case .mp3:
            try MP3Encoder.encode(pcm, to: url, lame: lame!, options: mp3)
            try ID3Tags.write(comments, cover: cover, to: url)
        }
    }

    /// A job's audio to encode: as ripped, HDCD decoded, de-emphasized, or both, at the
    /// format's bits. HDCD is decoded first, at 24 bits, and de-emphasis rounds to the format's.
    /// The end of the track before, if the encoding has it, settles the decoder and the filter,
    /// as in a player that plays the disc straight through.
    /// A job's audio: stereo, or the surround audio of a DTS decode.
    private enum JobAudio {
        case pcm(TrackPCM)
        case surround(SurroundPCM)
    }

    /// A job's audio to encode: a DTS stream decoded, with the tracks around it for the frames
    /// that cross its edges, else as `audio(of:in:decodes:)` gives it.
    private func audio(of job: Job, in disc: RippedDisc, decodes: Bool, dts: DTSDecoder?) throws -> JobAudio {
        guard job.isDTS, let dts else { return .pcm(try audio(of: job, in: disc, decodes: decodes)) }
        let samples = try disc.audio(of: job.ripped)
        let previous = try job.previous.map { try disc.audio(of: $0) }
        let next = try job.next.map { try disc.audio(of: $0) }
        return .surround(try dts.decode(samples, previous: previous?[...], next: next?[...]))
    }

    private func audio(of job: Job, in disc: RippedDisc, decodes: Bool) throws -> TrackPCM {
        let samples = try disc.audio(of: job.ripped)
        let usesPrevious = decodes || (job.deEmphasizes && job.previousDeEmphasizes)
        let previous = usesPrevious ? try job.previous.map { try disc.audio(of: $0) } : nil
        guard job.deEmphasizes else {
            return decodes
                ? .wide(HDCDCodes.decode(samples, bits: format.wideBits, previous: previous?[...])) : .cd(samples)
        }
        func source(_ samples: ArraySlice<UInt32>, before: ArraySlice<UInt32>?) -> TrackPCM {
            decodes ? .wide(HDCDCodes.decode(Array(samples), bits: 24, previous: before)) : .cd(Array(samples))
        }
        // The filter needs only the last frames of the track before, decoded as they play.
        let settling =
            job.previousDeEmphasizes
            ? previous.map { previous in
                let split = previous.count - min(previous.count, DeEmphasis.settlingFrames)
                return source(previous[split...], before: previous[..<split])
            } : nil
        return .wide(
            DeEmphasis.apply(source(samples[...], before: previous?[...]), bits: format.wideBits, previous: settling))
    }

    /// The tracks that hold a DTS stream: from the report, or for a rip from before Silverside
    /// looked, from the audio.
    public func dtsTracks(of disc: RippedDisc) throws -> Set<Int> {
        if let report = disc.report, report.dts != nil {
            return Set(report.tracks.filter { $0.dts == true }.map(\.number))
        }
        let found = CTDB.parallelMap(over: disc.tracks, lanes: parallelTracks) {
            track -> Result<Int?, any Error>? in
            Result { DTSStream.isStream(try disc.audio(of: track)) ? track.number : nil }
        }
        return Set(try found.compactMap { try $0.get() })
    }

    /// Sets which tracks hold a DTS stream in a report from before Silverside looked.
    static func recordDTS(_ tracks: Set<Int>, in report: inout RipReport) {
        for index in report.tracks.indices {
            report.tracks[index].dts = tracks.contains(report.tracks[index].number) ? true : nil
        }
        report.dts = DTSStatus(report.tracks)
    }

    /// Whether the disc's HDCD codes ask for anything: from its report, or for a rip from
    /// before Silverside looked for them, from its audio.
    func hdcdStatus(of disc: RippedDisc) throws -> HDCDStatus {
        if let known = disc.report?.hdcd { return known }
        let found = CTDB.parallelMap(over: disc.tracks, lanes: parallelTracks) {
            track -> Result<HDCDCodes?, any Error>? in
            Result { HDCDCodes.scan(try disc.audio(of: track)) }
        }
        let codes = try found.compactMap { try $0.get() }
        return codes.isEmpty ? .noCodes : codes.contains(where: \.changesAudio) ? .featuresUsed : .codesOnly
    }

    /// Encodes one track: reads its audio, writes a partial file, checks it, and moves it
    /// into place. With `staging`, it leaves the checked partial file for the caller to move,
    /// and returns it. Runs on one of the encoding lanes.
    private func encode(
        _ job: Job, of disc: RippedDisc, decodes: Bool, dts: DTSDecoder?, cover: EmbeddedCover?, lame: URL?,
        staging: Bool, outcomes: EncodeOutcomes
    ) throws -> URL? {
        try FileManager.default.createDirectory(at: job.folder, withIntermediateDirectories: true)
        let samples = try audio(of: job, in: disc, decodes: decodes, dts: dts)
        if case .surround(let surround) = samples { outcomes.surroundLayout = surround.layoutName }
        // Write to a partial file, and move it into place only when it is checked.
        let partial = job.folder.appending(path: ".\(UUID().uuidString).partial.\(format.fileExtension)")
        var keepsPartial = false
        defer { if !keepsPartial { try? FileManager.default.removeItem(at: partial) } }
        try write(samples, metadata: job.metadata, extra: job.extraComments, cover: cover, to: partial, lame: lame)
        try check(partial, against: samples, final: job.file)
        if staging {
            keepsPartial = true
            return partial
        }
        if FileManager.default.fileExists(atPath: job.file.path) { try FileManager.default.removeItem(at: job.file) }
        try FileManager.default.moveItem(at: partial, to: job.file)
        trackEncoded(job.ripped.number, job.file)
        return nil
    }

    /// Decodes the file: a lossless file must give the samples it was made from; a lossy one, about as many.
    private func check(_ url: URL, against audio: JobAudio, final: URL) throws {
        let matches: Bool
        switch audio {
        case .surround(let surround):
            let decoded = try AudioEncoder.decodeSurround(url)
            matches =
                decoded.channels == surround.channels
                && (format.isLossless
                    ? decoded.values == surround.values : abs(decoded.frameCount - surround.frameCount) < 4 * 1152)
        case .pcm(.cd(let samples)):
            let decoded = try AudioEncoder.decode(url)
            matches = format.isLossless ? decoded == samples : abs(decoded.count - samples.count) < 4 * 1152
        case .pcm(.wide(let values)):
            let decoded = try AudioEncoder.decodeWide(url)
            matches = format.isLossless ? decoded == values : abs(decoded.count - values.count) < 8 * 1152
        }
        guard matches else { throw EncodingError.verificationFailed(final) }
    }
}

/// Which tracks the encoding lanes finished, and the errors of those that failed. Each
/// finished track's line goes to the log in the tracks' order, as soon as the tracks before
/// it are done: the lanes finish in any order.
private final class EncodeOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var done = Set<Int>()
    private var errors = [Int: any Error]()
    private let log: @Sendable (String) -> Void
    /// The lines of the jobs that ended, by job, until the jobs before them end too; nil for a
    /// job with no line (it failed, or its file is named later).
    private var lines = [Int: String?]()
    private var nextLine = 0

    private var partials = [Int: URL]()
    private var layout: String?

    /// The layout of the surround audio that a DTS decode wrote, such as "5.1".
    var surroundLayout: String? {
        get { lock.withLock { layout } }
        set { lock.withLock { layout = newValue } }
    }

    init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    var hasFailed: Bool { lock.withLock { !errors.isEmpty } }
    /// The checked partial files of a staged encoding, by job.
    var staged: [Int: URL] { lock.withLock { partials } }
    func finish(_ index: Int, staged: URL?, line: String?) {
        lock.withLock {
            done.insert(index)
            if let staged { partials[index] = staged }
            settle(index, line: line)
        }
    }
    func finished(_ index: Int) -> Bool { lock.withLock { done.contains(index) } }
    func fail(_ index: Int, _ error: any Error) {
        lock.withLock {
            errors[index] = error
            settle(index, line: nil)
        }
    }

    /// Logs the lines still waiting, in order: after a failure, the jobs before them never ran.
    func logTheRest() {
        lock.withLock {
            for index in lines.keys.sorted() { if let line = lines[index] ?? nil { log(line) } }
            lines = [:]
        }
    }

    private func settle(_ index: Int, line: String?) {
        lines[index] = .some(line)
        while let entry = lines[nextLine] {
            if let entry { log(entry) }
            lines[nextLine] = nil
            nextLine += 1
        }
    }
    /// The error of the first job that failed, in the jobs' order.
    var firstError: (any Error)? { lock.withLock { errors.min { $0.key < $1.key }?.value } }
}
