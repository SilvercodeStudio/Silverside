import Foundation

/// Disc images: the whole disc's audio in one lossless file, with a CUE sheet, from which a
/// burner rebuilds the disc as the per-track files do (see `CueSheet`). Some players and
/// archivists prefer one file a disc. Data tracks, and the subchannels that CD+G uses, are not
/// in it.
extension DiscEncoder {
    /// The image's format: the library's, if it is lossless, else FLAC, as a lossy file cannot
    /// rebuild the disc.
    public var imageFormat: AudioFormat { format.isLossless ? format : .flac }

    /// Where the image of the album in `albumFolder` goes: the same folder names under `images`
    /// as under the library ("Artist/Album"), or the album folder's name alone if it is not in
    /// the library.
    func imageFolder(for albumFolder: URL, library: URL, images: URL) -> URL {
        let album = albumFolder.standardizedFileURL.pathComponents
        let root = library.standardizedFileURL.pathComponents
        let names = album.starts(with: root) && album.count > root.count ? album.dropFirst(root.count) : [album.last!]
        return names.reduce(images) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }

    /// The album's tags for the image, which players show as one long track: the album's names
    /// and IDs, and the album as its title.
    func imageTags(
        sheet: CueSheet, release: MusicBrainzRelease, medium: MusicBrainzRelease.Medium, hdcd: HDCDStatus?
    ) -> [(key: String, value: String)] {
        let albumKeys: Set = [
            "ALBUM", "ALBUMARTIST", "DISCNUMBER", "DISCTOTAL", "DISCSUBTITLE", "COMPILATION", "DATE", "ORIGINALDATE",
            "GENRE", "BARCODE", "LABEL", "CATALOGNUMBER", "RELEASECOUNTRY", "ALBUMARTISTSORT", "MUSICBRAINZ_ALBUMID",
            "MUSICBRAINZ_RELEASEGROUPID", "MUSICBRAINZ_ALBUMARTISTID",
        ]
        let sample = TrackMetadata(
            release: release, medium: medium, track: medium.tracks[0], liveShowStyle: liveShowStyle,
            plainPunctuation: plainPunctuation, segueMarks: segueMarks, compilationFolder: compilationFolder)
        var tags = sample.vorbisComments.filter { albumKeys.contains($0.key) }
        if let album = sheet.title { tags.insert(("TITLE", album), at: 0) }
        if let artist = sheet.performer { tags.insert(("ARTIST", artist), at: 0) }
        tags += HDCDStatus.tags(hdcd, decoded: false)
        return tags
    }

    /// Writes the disc image into `folder`, as `name` with the format's extension and ".cue":
    /// every track's audio as it is on the disc, one after another (the hidden track one
    /// audio first), a track at a time. The file is decoded again, and its CRC-32 must equal
    /// the audio's, before it replaces an older image. A FLAC image also holds the CUE sheet
    /// in its tags, where some players read the tracks. Returns the image file.
    func writeImage(
        of disc: RippedDisc, sheet: CueSheet, name: String, folder: URL, tags: [(key: String, value: String)],
        cover: EmbeddedCover?
    ) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name + "." + imageFormat.fileExtension)
        let partial = folder.appending(path: ".\(UUID().uuidString).partial.\(imageFormat.fileExtension)")
        defer { try? FileManager.default.removeItem(at: partial) }

        var tracks = disc.tracks[...]
        var crc: UInt32 = 0
        var frames = 0
        var hiddenFrames = 0
        let next = { () throws -> [UInt32]? in
            guard let track = tracks.popFirst() else { return nil }
            let samples = try disc.audio(of: track)
            if track.number == 0 { hiddenFrames = samples.count }
            crc = CRC32.checksum(of: samples[...], after: crc)
            frames += samples.count
            return samples
        }
        if imageFormat == .wav {
            try WAVFile.write(to: partial, parts: next)
        } else {
            try AudioEncoder.encode(format: imageFormat, to: partial, parts: next)
        }

        var checked: UInt32 = 0
        var checkedFrames = 0
        try AudioEncoder.decode(partial) { part in
            checked = CRC32.checksum(of: part, after: checked)
            checkedFrames += part.count
        }
        guard checked == crc && checkedFrames == frames else { throw EncodingError.verificationFailed(file) }

        var sheet = sheet
        sheet.imageFile = file.lastPathComponent
        sheet.hiddenTrackSectors = hiddenFrames / CDDA.samplesPerSector
        switch imageFormat {
        case .flac: try FLACTags.write(tags + [("CUESHEET", sheet.text)], cover: cover, to: partial)
        case .alac: try MP4Tags.write(tags, cover: cover, to: partial)
        case .aiff: try ChunkTags.writeAIFF(tags, cover: cover, to: partial)
        case .wav: try ChunkTags.writeWAV(tags, cover: cover, to: partial)
        case .aac, .mp3: break
        }
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try FileManager.default.moveItem(at: partial, to: file)

        try Data(sheet.text.utf8).write(to: folder.appending(path: name + ".cue"))
        log("Disc image: \(file.path)")
        return file
    }
}
