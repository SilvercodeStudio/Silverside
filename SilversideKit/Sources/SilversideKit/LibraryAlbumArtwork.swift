import Foundation

/// The other images to save in an album folder's Artwork: every image of the release but the
/// cover (and the archive's raw, unedited scans), or the ones the user names.
public enum ArtworkSelection: Equatable, Sendable {
    /// Every image but the cover and raw scans; for a folder that holds some discs of a set,
    /// those whose comment names another disc are left out (`CoverArtImage.mediums`).
    case all
    /// Cover Art Archive image IDs, in the order to save them.
    case images([String])
}

/// What `silverside album` changes in an album folder for its artwork, worked out before
/// anything is written, so the user can read it first: the cover each file embeds, the
/// folder's cover file, its Artwork, and the choice kept in the folder. Every tag but the
/// cover stays as it is.
public struct AlbumArtworkPlan: Sendable {
    public enum FileChange: Equatable, Sendable {
        /// The file gets the cover, in place of the one it has, if any.
        case embed(replacing: LibraryAlbum.Picture?)
        /// The file has this cover already.
        case unchanged
        /// Silverside does not change this kind of file yet (MP3, AIFF, WAV, ...), or an MP4
        /// file whose tags are not iTunes's (`LibraryAlbum.File.canWriteCover`).
        case unsupported
    }

    public struct FilePlan: Sendable {
        public var file: LibraryAlbum.File
        public var change: FileChange
    }

    public enum CoverFileChange: Equatable, Sendable {
        /// The folder has no cover file.
        case write
        /// The folder's cover file is another image.
        case replace(LibraryAlbum.Picture?)
        case unchanged
    }

    public struct ArtworkImage: Sendable {
        public var image: CoverArtImage
        /// The file's name in Artwork, with no extension (`CoverArtImage.fileNames`).
        public var name: String
    }

    public enum ArtworkChange: Sendable {
        /// None chosen: Artwork stays as it is.
        case leave
        /// The same images as the last run saved, all there.
        case unchanged
        /// Artwork gets these images, in place of what it has.
        case replace([ArtworkImage])
    }

    public var album: LibraryAlbum
    public var release: MusicBrainzRelease
    /// Every image the archive has for the release, in its order.
    public var images: [CoverArtImage]
    public var front: CoverArtImage
    /// True if the cover is the disc's own sleeve in a box set (`CoverArtImage.sleeve`), which
    /// a folder of one disc of the set takes by default.
    public var frontIsSleeve: Bool
    /// With `--artwork all` in a folder of some discs of a set: the images left out because
    /// their comments name other discs.
    public var otherDiscsImages: Int
    /// The front at full size, for the cover file: as the archive has it if JPEG or PNG, else a JPEG.
    public var cover: CoverImage
    public var coverPicture: LibraryAlbum.Picture
    /// The front as the files embed it (`EmbeddedCover`, 1000 pixels at most).
    public var embedded: EmbeddedCover
    public var embeddedPicture: LibraryAlbum.Picture
    public var files: [FilePlan]
    public var coverFile: CoverFileChange
    public var artwork: ArtworkChange
    public var choice: AlbumChoice

    /// True if writing would change anything.
    public var hasChanges: Bool {
        if files.contains(where: { if case .embed = $0.change { true } else { false } }) { return true }
        if coverFile != .unchanged { return true }
        if case .replace = artwork { return true }
        return !choice.sameChoice(as: album.choice)
    }

    /// Works out the plan: the release's images from the Cover Art Archive, and its cover at
    /// full size, which the plan shows by its size. `front` is an image ID; nil takes the one
    /// kept in the folder for this release, else the disc's own sleeve when the folder is one
    /// disc of a set, else the release's main front. `artwork` nil keeps what an earlier run
    /// chose for this release, else leaves Artwork alone. `media` are the release's discs
    /// that the folder holds (`AlbumFit.media`), if known.
    public static func make(
        album: LibraryAlbum, release: MusicBrainzRelease, media: [Int]? = nil, front frontID: String? = nil,
        artwork selection: ArtworkSelection? = nil, client: CoverArtClient = CoverArtClient()
    ) async throws -> AlbumArtworkPlan {
        let images = try await client.images(releaseID: release.id)
        guard !images.isEmpty else { throw AlbumArtworkError.noImages(release.id) }
        let kept = album.choice?.releaseID == release.id ? album.choice : nil
        // Some discs of a set: the images that name other discs are theirs.
        let discs = media.flatMap { $0.count < release.media.count ? Set($0) : nil }
        let sleeve = discs.flatMap { $0.count == 1 ? CoverArtImage.sleeve(forDisc: $0.first!, in: images) : nil }
        let front: CoverArtImage
        if let frontID {
            guard let image = images.first(where: { $0.id == frontID }) else {
                throw AlbumArtworkError.noSuchImage(frontID)
            }
            front = image
        } else if let id = kept?.frontImageID, let image = images.first(where: { $0.id == id }) {
            front = image
        } else if let sleeve {
            front = sleeve
        } else if let image = images.first(where: \.isFront) {
            front = image
        } else {
            throw AlbumArtworkError.noFront(release.id)
        }
        guard let data = try await client.client.data(from: front.url) else {
            throw AlbumArtworkError.noSuchImage(front.id)
        }
        let cover = try CoverImage(converting: data)
        let embedded = try EmbeddedCover(cover)
        let embeddedPicture = LibraryAlbum.Picture(data: embedded.image.data)

        let files = album.files.map { file -> FilePlan in
            guard file.canWriteCover else { return FilePlan(file: file, change: .unsupported) }
            if file.cover?.isSamePicture(as: embeddedPicture) == true {
                return FilePlan(file: file, change: .unchanged)
            }
            return FilePlan(file: file, change: .embed(replacing: file.cover))
        }
        let coverPicture = LibraryAlbum.Picture(data: cover.data)
        let coverFile: CoverFileChange =
            album.coverFile == nil
            ? .write
            : album.coverPicture?.isSamePicture(as: coverPicture) == true
                ? .unchanged : .replace(album.coverPicture)

        let chosen: [CoverArtImage]?
        var otherDiscsImages = 0
        switch selection ?? kept?.artworkImageIDs.map(ArtworkSelection.images) {
        case nil:
            chosen = nil
        case .all:
            let all = images.filter { $0.id != front.id && !$0.types.contains("Raw/Unedited") }
            chosen = all.filter { image in
                guard let discs, let named = image.mediums else { return true }
                return discs.contains(where: named.contains)
            }
            otherDiscsImages = all.count - (chosen?.count ?? 0)
        case .images(let ids):
            chosen = try ids.map { id in
                guard let image = images.first(where: { $0.id == id }) else { throw AlbumArtworkError.noSuchImage(id) }
                return image
            }
        }
        let artwork: ArtworkChange
        if let chosen {
            let ids = chosen.map(\.id)
            artwork =
                ids == kept?.artworkImageIDs && album.artworkCount == ids.count
                ? .unchanged
                : .replace(zip(chosen, CoverArtImage.fileNames(for: chosen)).map { ArtworkImage(image: $0, name: $1) })
        } else {
            artwork = .leave
        }
        var choice = AlbumChoice(
            releaseID: release.id, release: "\(release.artist) - \(release.title)", frontImageID: front.id,
            artworkImageIDs: chosen.map { $0.map(\.id) } ?? kept?.artworkImageIDs)
        // What the tags chose stays, so the cover alone is no change to the choice.
        choice.media = kept?.media
        choice.album = kept?.album
        return AlbumArtworkPlan(
            album: album, release: release, images: images, front: front, frontIsSleeve: front.id == sleeve?.id,
            otherDiscsImages: otherDiscsImages, cover: cover, coverPicture: coverPicture,
            embedded: embedded, embeddedPicture: embeddedPicture, files: files, coverFile: coverFile,
            artwork: artwork, choice: choice)
    }

    /// One step of `apply`, for the user to follow.
    public typealias Step = AlbumPlan.Step

    /// Writes the plan, as `AlbumPlan` does with no tags.
    public func apply(client: CoverArtClient = CoverArtClient(), step: @Sendable (Step) -> Void = { _ in })
        async throws
    {
        try await AlbumPlan(album: album, release: release, artwork: self, tags: nil).apply(client: client, step: step)
    }
}

/// Everything `silverside album` changes in an album folder: the artwork (`AlbumArtworkPlan`)
/// and the tags (`AlbumTagsPlan`), either of which may be left out, and the choice kept in
/// the folder. Each file is written once, with its cover and its tags.
public struct AlbumPlan: Sendable {
    public var album: LibraryAlbum
    public var release: MusicBrainzRelease
    public var artwork: AlbumArtworkPlan?
    public var tags: AlbumTagsPlan?
    public var choice: AlbumChoice

    public init(album: LibraryAlbum, release: MusicBrainzRelease, artwork: AlbumArtworkPlan?, tags: AlbumTagsPlan?) {
        self.album = album
        self.release = release
        self.artwork = artwork
        self.tags = tags
        // Without the artwork, the images kept for this release stay chosen.
        let kept = album.choice?.releaseID == release.id ? album.choice : nil
        var choice =
            artwork?.choice
            ?? AlbumChoice(
                releaseID: release.id, release: "\(release.artist) - \(release.title)",
                frontImageID: kept?.frontImageID, artworkImageIDs: kept?.artworkImageIDs)
        choice.media = tags?.fit.media ?? kept?.media
        if let tags { choice.album = tags.editedAlbumTitle } else { choice.album = kept?.album }
        self.choice = choice
    }

    /// True if writing would change anything.
    public var hasChanges: Bool {
        (artwork?.hasChanges ?? false) || (tags?.hasChanges ?? false) || !choice.sameChoice(as: album.choice)
    }

    /// One step of `apply`, for the user to follow.
    public enum Step: Sendable {
        case downloadingArtwork(count: Int)
        case wroteFile(URL)
        case wroteCover(URL)
        case wroteArtwork(count: Int)
        case keptChoice(URL)
    }

    /// Writes the plan: the Artwork images are downloaded first, so a failed download changes
    /// nothing; then each file gets its cover and its tags, in one write (its audio checked,
    /// `LibraryAlbumWriter`); then the cover file, Artwork, and the choice.
    public func apply(client: CoverArtClient = CoverArtClient(), step: @Sendable (Step) -> Void = { _ in })
        async throws
    {
        let manager = FileManager.default
        var staged: (folder: URL, files: [URL])?
        if let artwork, case .replace(let images) = artwork.artwork {
            step(.downloadingArtwork(count: images.count))
            let folder = manager.temporaryDirectory.appending(
                path: "silverside-artwork-\(UUID().uuidString)", directoryHint: .isDirectory)
            staged = (folder, try await client.save(images.map { ($0.image, $0.name) }, in: folder))
        }
        defer { if let staged { try? manager.removeItem(at: staged.folder) } }
        for (index, file) in album.files.enumerated() {
            var cover: EmbeddedCover?
            if let artwork, index < artwork.files.count, case .embed = artwork.files[index].change {
                cover = artwork.embedded
            }
            let fileTags = tags.flatMap { index < $0.files.count ? $0.files[index] : nil }
                .flatMap { $0.canWrite && !$0.changes.isEmpty ? $0 : nil }
            guard cover != nil || fileTags != nil else { continue }
            try Task.checkCancellation()
            try await blocking {
                try LibraryAlbumWriter.update(file.url, kind: file.kind, cover: cover, tags: fileTags)
            }
            step(.wroteFile(file.url))
        }
        if let artwork, artwork.coverFile != .unchanged {
            let written = try artwork.cover.write(to: album.folder)
            // A cover file of the other format would be found first.
            if let old = album.coverFile, old.standardizedFileURL != written.standardizedFileURL {
                try manager.removeItem(at: old)
            }
            step(.wroteCover(written))
        }
        if let staged {
            try ArtworkFolder.replace(in: album.folder, with: staged.folder, files: staged.files)
            step(.wroteArtwork(count: staged.files.count))
        }
        if hasChanges {
            try choice.save(in: album.folder)
            step(.keptChoice(album.folder.appending(path: AlbumChoice.fileName)))
        }
    }
}

extension AlbumChoice {
    /// True if `other` chose the same release, images, and album name, whenever and by whichever version.
    func sameChoice(as other: AlbumChoice?) -> Bool {
        guard let other else { return false }
        return releaseID == other.releaseID && frontImageID == other.frontImageID
            && artworkImageIDs == other.artworkImageIDs && (media == nil || media == other.media)
            && album == other.album
    }
}

/// Changes the tags of a file in place, as safely as a file on a network share allows: the new
/// contents are made in memory and their audio checked against the file's (`AudioPayload`),
/// written beside the file and checked again as read back, and only then put in its place,
/// with the file's own attributes kept (`FileManager.replaceItemAt`).
public enum LibraryAlbumWriter {
    /// Gives the file `cover` as its front cover, keeping every other tag.
    public static func replaceCover(in url: URL, kind: AudioFileKind, with cover: EmbeddedCover) throws {
        try update(url, kind: kind, cover: cover, tags: nil)
    }

    /// Gives the file `cover` as its front cover (nil keeps it) and `tags`' merge of its tags
    /// (nil keeps them), in one write.
    public static func update(
        _ url: URL, kind: AudioFileKind, cover: EmbeddedCover?, tags: AlbumTagsPlan.FilePlan?
    ) throws {
        try rewrite(url, kind: kind) { data in
            switch kind {
            case .flac: try FLACTags.updating(data, comments: tags?.merged, cover: cover)
            case .mp4:
                try MP4Tags.updating(data, removing: tags?.removed ?? [], adding: tags?.written ?? [], cover: cover)
            case .other: throw AudioPayloadError.unsupported
            }
        }
    }

    static func rewrite(_ url: URL, kind: AudioFileKind, _ change: (Data) throws -> Data) throws {
        let data = try Data(contentsOf: url)
        let before = try AudioPayload.fingerprint(of: data, kind: kind)
        let new = try change(data)
        guard try AudioPayload.fingerprint(of: new, kind: kind) == before else { throw AudioPayloadError.changed(url) }
        let manager = FileManager.default
        let temporary = url.deletingLastPathComponent().appending(
            path: ".silverside-\(UUID().uuidString).\(url.pathExtension)")
        try new.write(to: temporary)
        do {
            guard try AudioPayload.fingerprint(of: Data(contentsOf: temporary), kind: kind) == before else {
                throw AudioPayloadError.changed(url)
            }
            _ = try manager.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }
}

public enum AlbumArtworkError: Error, Equatable, CustomStringConvertible {
    case noImages(String)
    case noFront(String)
    case noSuchImage(String)

    public var description: String {
        switch self {
        case .noImages(let id): "The Cover Art Archive has no images for release \(id)."
        case .noFront(let id): "The Cover Art Archive has no front cover for release \(id): choose one with --front."
        case .noSuchImage(let id): "The release has no image \(id) in the Cover Art Archive."
        }
    }
}
