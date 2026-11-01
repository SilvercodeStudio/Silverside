import Foundation

/// A cover image, as the Cover Art Archive or the user gives it.
public struct CoverImage: Equatable, Sendable {
    public var data: Data

    public init(data: Data) {
        self.data = data
    }

    /// The file extension for the image's format, from its first bytes, or nil if the
    /// format is not one that tags can hold (JPEG or PNG).
    public var fileExtension: String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        return nil
    }

    /// The MIME type, as FLAC PICTURE blocks and MP4 tags record it.
    public var mimeType: String? {
        switch fileExtension {
        case "jpg": "image/jpeg"
        case "png": "image/png"
        default: nil
        }
    }

    /// Writes the image as "<name>.jpg" or "<name>.png" in `folder` (by default "cover"),
    /// and returns the file.
    @discardableResult
    public func write(to folder: URL, name: String = "cover") throws -> URL {
        guard let fileExtension else { throw CoverArtError.unknownFormat }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(name).\(fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// The cover files in a rip's folder or an album folder: "cover.jpg" (or .png) is the album's,
/// and "cover (Disc 2).jpg" a disc's own, such as a box set's sleeve, which that disc's files
/// embed in place of the album's.
public enum CoverFiles {
    static let extensions = ["jpg", "png"]

    /// "cover (Disc 2)", with no extension.
    public static func discName(_ position: Int) -> String { "cover (Disc \(position))" }

    /// The album's cover file in `folder`, if it has one.
    public static func album(in folder: URL) -> URL? {
        existing(extensions.map { folder.appending(path: "cover.\($0)") })
    }

    /// The disc's own cover file in `folder`, if it has one.
    public static func disc(_ position: Int?, in folder: URL) -> URL? {
        guard let position else { return nil }
        return existing(extensions.map { folder.appending(path: "\(discName(position)).\($0)") })
    }

    /// The cover that the disc's files embed: its own, else the album's.
    public static func embedded(forDisc position: Int?, in folder: URL) -> URL? {
        disc(position, in: folder) ?? album(in: folder)
    }

    /// Writes the disc's own cover into `folder`, in place of an older one.
    @discardableResult
    static func writeDisc(_ cover: CoverImage, position: Int, in folder: URL) throws -> URL {
        try removeDisc(position, in: folder)
        return try cover.write(to: folder, name: discName(position))
    }

    /// Removes the disc's own cover from `folder`: its files take the album's again.
    static func removeDisc(_ position: Int, in folder: URL) throws {
        for file in extensions.map({ folder.appending(path: "\(discName(position)).\($0)") })
        where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private static func existing(_ files: [URL]) -> URL? {
        files.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

public enum CoverArtError: Error, Equatable, CustomStringConvertible {
    case unknownFormat
    case notAnImage
    case malformedListing

    public var description: String {
        switch self {
        case .unknownFormat: "The cover image is not a JPEG or PNG file."
        case .notAnImage:
            "The cover file cannot be read as a picture. Use a JPEG, PNG, HEIC, WebP, TIFF, or GIF file; "
                + "a drawing such as SVG or PDF must first be saved as one of those."
        case .malformedListing: "The Cover Art Archive's list of images cannot be read."
        }
    }
}

/// Gets cover art from the Cover Art Archive, through `WebClient`.
public struct CoverArtClient: Sendable {
    public let client: WebClient

    public init(client: WebClient = .shared) {
        self.client = client
    }

    static func frontCoverURL(releaseID: String) -> URL {
        URL(string: "https://coverartarchive.org/release/\(releaseID)/front")!
    }

    /// The release's front cover, at the size it was uploaded, or nil if the archive has none.
    public func frontCover(releaseID: String) async throws -> CoverImage? {
        try await client.data(from: Self.frontCoverURL(releaseID: releaseID)).map(CoverImage.init)
    }

    /// Every image that the archive has for the release, in the archive's order. Empty if it has none.
    public func images(releaseID: String) async throws -> [CoverArtImage] {
        let url = URL(string: "https://coverartarchive.org/release/\(releaseID)")!
        guard let data = try await client.data(from: url) else { return [] }
        return try Self.images(fromJSON: data)
    }

    /// The images that stand for a release group: those of the release that the archive
    /// takes for the group (one that editors chose, else one of its releases with a front
    /// cover), with that release's ID. Nil if no release of the group has a front cover.
    public func releaseGroupArtwork(releaseGroupID: String) async throws -> (
        releaseID: String, images: [CoverArtImage]
    )? {
        let url = URL(string: "https://coverartarchive.org/release-group/\(releaseGroupID)")!
        guard let data = try await client.data(from: url) else { return nil }
        let listing = try Self.listing(fromJSON: data)
        guard let release = listing.release, !listing.images.isEmpty else { return nil }
        return (release, listing.images)
    }

    /// The front cover that stands for the release: the front of `source` (another release
    /// whose artwork the user chose for it, `ReleaseCoverStore.artworkRelease`), else its
    /// own, else its release group's, which the archive takes from another release of the
    /// group. Nil if there is none.
    public func frontCover(of release: MusicBrainzRelease, from source: String? = nil) async throws -> CoverImage? {
        if let source, source != release.id { return try await frontCover(releaseID: source) }
        if release.hasFrontCover { return try await frontCover(releaseID: release.id) }
        guard !release.isManual, let group = release.releaseGroup?.id else { return nil }
        let url = URL(string: "https://coverartarchive.org/release-group/\(group)/front")!
        return try await client.data(from: url).map(CoverImage.init)
    }

    /// One image, at the size it was uploaded.
    public func download(_ image: CoverArtImage) async throws -> CoverImage? {
        try await client.data(from: image.url).map(CoverImage.init)
    }

    /// The disc's own sleeve in a box set (see `CoverArtImage.sleeve`), at full size. Nil if
    /// the archive has none for it.
    public func discSleeve(releaseID: String, disc position: Int) async throws -> CoverImage? {
        guard let sleeve = CoverArtImage.sleeve(forDisc: position, in: try await images(releaseID: releaseID))
        else { return nil }
        return try await download(sleeve)
    }

    /// A small copy of the image (250 pixels), for a choice among a release's images. Nil if
    /// the archive has none.
    public func thumbnail(_ image: CoverArtImage) async throws -> Data? {
        guard let url = image.thumbnailURL else { return nil }
        return try await client.data(from: url)
    }

    static func images(fromJSON data: Data) throws -> [CoverArtImage] {
        try listing(fromJSON: data).images
    }

    /// A listing's images, and the release they belong to (a release group's listing names
    /// it: "release": "https://musicbrainz.org/release/<ID>").
    static func listing(fromJSON data: Data) throws -> (release: String?, images: [CoverArtImage]) {
        struct Listing: Decodable {
            struct Image: Decodable {
                var id: AnyID
                var types: [String]?
                var front: Bool?
                var back: Bool?
                var image: String
                var comment: String?
                var thumbnails: [String: String]?
            }
            var images: [Image]
            var release: String?
        }
        // The archive gives image IDs as numbers, or in older answers as strings.
        struct AnyID: Decodable {
            var text: String
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Int.self) {
                    text = String(number)
                } else {
                    text = try container.decode(String.self)
                }
            }
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else {
            throw CoverArtError.malformedListing
        }
        // The archive's links are http; the same files are served over https.
        func secure(_ link: String?) -> URL? {
            guard let link, var components = URLComponents(string: link) else { return nil }
            components.scheme = "https"
            return components.url
        }
        let images = listing.images.compactMap { image -> CoverArtImage? in
            guard let url = secure(image.image) else { return nil }
            let thumbnails = image.thumbnails ?? [:]
            return CoverArtImage(
                id: image.id.text, types: image.types ?? [], isFront: image.front ?? false,
                isBack: image.back ?? false, url: url, comment: image.comment ?? "",
                thumbnailURL: secure(thumbnails["250"] ?? thumbnails["small"] ?? thumbnails["500"]))
        }
        return (listing.release.flatMap { URL(string: $0)?.lastPathComponent }, images)
    }

    /// Saves the release's artwork in `folder`: the front cover as "cover.jpg" (or .png),
    /// and, if `all`, the other images in "Artwork" (see `CoverArtImage.fileNames`).
    /// Returns the files written.
    public func save(releaseID: String, in folder: URL, all: Bool) async throws -> [URL] {
        try await save(try await images(releaseID: releaseID), in: folder, all: all)
    }

    /// Saves `images` (one release's listing) as `save(releaseID:in:all:)` does.
    func save(_ images: [CoverArtImage], in folder: URL, all: Bool) async throws -> [URL] {
        var written = [URL]()
        if let front = images.first(where: \.isFront), let image = try await download(front) {
            written.append(try image.write(to: folder))
        }
        guard all else { return written }
        return written + (try await saveOthers(images, in: folder.appending(path: "Artwork")))
    }

    /// Saves the images but the main front in `artwork`, named by `CoverArtImage.fileNames`,
    /// three at a time: full-size scans are many megabytes each, and the web client still
    /// spaces the requests as the archive asks. The files keep the archive's order.
    func saveOthers(_ images: [CoverArtImage], in artwork: URL) async throws -> [URL] {
        let others = Array(
            zip(images.filter { !$0.isFront }, CoverArtImage.fileNames(for: images.filter { !$0.isFront })))
        let saved = try await withThrowingTaskGroup(of: (Int, URL?).self) { group -> [URL?] in
            var results = [URL?](repeating: nil, count: others.count)
            var next = 0
            func add() {
                guard next < others.count else { return }
                let (index, (image, name)) = (next, others[next])
                next += 1
                group.addTask { (index, try await download(image).map { try $0.write(to: artwork, name: name) }) }
            }
            for _ in 0..<3 { add() }
            while let (index, file) = try await group.next() {
                results[index] = file
                add()
            }
            return results
        }
        return saved.compactMap { $0 }
    }

    /// The images that stand for the release: `source`'s (another release the user chose),
    /// else its own, else its release group's, with the other release they come from.
    public func artworkImages(of release: MusicBrainzRelease, from source: String? = nil) async throws -> (
        images: [CoverArtImage], fromRelease: String?
    ) {
        if let source, source != release.id { return (try await images(releaseID: source), source) }
        if release.hasFrontCover || (release.artworkCount ?? 0) > 0 {
            return (try await images(releaseID: release.id), nil)
        }
        guard !release.isManual, let group = release.releaseGroup?.id,
            let found = try await releaseGroupArtwork(releaseGroupID: group), found.releaseID != release.id
        else { return ([], nil) }
        return (found.images, found.releaseID)
    }

    /// Puts `images` but the main front (the cover, which a retag changes) in place of the
    /// Artwork folder of each of `folders`: earlier rips' folders and their album folders.
    /// The images are downloaded first, and each folder's old Artwork is removed only when
    /// its new one is in place, so a failure leaves it as it was. A rip's disc.json lists the
    /// new files. Returns the number of images in each folder's Artwork now.
    public func replaceArtwork(with images: [CoverArtImage], in folders: [URL]) async throws -> Int {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appending(
            path: "silverside-artwork-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? manager.removeItem(at: staging) }
        let saved = try await saveOthers(images, in: staging)
        try Task.checkCancellation()
        var seen = Set<String>()
        for folder in folders where seen.insert(folder.standardizedFileURL.resolvingSymlinksInPath().path).inserted {
            try ArtworkFolder.replace(in: folder, with: staging, files: saved)
        }
        return saved.count
    }
}

/// The Artwork folder of a rip or an album: the release's images but its cover.
public enum ArtworkFolder {
    /// The images in `folder`'s Artwork.
    public static func count(in folder: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "Artwork").path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.count
    }

    /// Copies `staged` into `folder` as its Artwork, in place of the one there. The copy goes
    /// in under another name first; the old folder is moved aside, the copy takes its name,
    /// and only then is the old one removed (put back if the rename fails). A disc.json in
    /// `folder` with a list of files gets `files` (in `staged`) as Artwork/... in place of its old ones.
    static func replace(in folder: URL, with staged: URL, files: [URL]) throws {
        let manager = FileManager.default
        let artwork = folder.appending(path: "Artwork", directoryHint: .isDirectory)
        let copy = folder.appending(path: ".silverside-artwork-\(UUID().uuidString)", directoryHint: .isDirectory)
        let aside = folder.appending(path: ".silverside-artwork-old-\(UUID().uuidString)", directoryHint: .isDirectory)
        if files.isEmpty {
            try manager.createDirectory(at: copy, withIntermediateDirectories: true)
        } else {
            try manager.copyItem(at: staged, to: copy)
        }
        let hadArtwork = manager.fileExists(atPath: artwork.path)
        do {
            if hadArtwork { try manager.moveItem(at: artwork, to: aside) }
            do {
                try manager.moveItem(at: copy, to: artwork)
            } catch {
                if hadArtwork { try? manager.moveItem(at: aside, to: artwork) }
                throw error
            }
        } catch {
            try? manager.removeItem(at: copy)
            throw error
        }
        try? manager.removeItem(at: aside)
        if files.isEmpty { try? manager.removeItem(at: artwork) }

        let reportFile = folder.appending(path: "disc.json")
        guard manager.fileExists(atPath: reportFile.path), var report = try? RipReport.read(from: reportFile),
            let listed = report.files
        else { return }
        let names = files.map { "Artwork/" + $0.lastPathComponent }
        report.files = (listed.filter { !$0.hasPrefix("Artwork/") } + names).sorted()
        try report.write(to: reportFile)
    }
}

/// One image in the Cover Art Archive.
public struct CoverArtImage: Equatable, Identifiable, Sendable {
    public var id: String
    /// "Front", "Back", "Booklet", "Medium", "Tray", "Obi", "Spine", "Track", "Liner", "Sticker", and so on.
    public var types: [String]
    /// The release's main front cover, which Silverside uses unless the user chooses another.
    /// A release can have more images of the type "Front" (such as each disc's sleeve in a box set).
    public var isFront: Bool
    public var isBack: Bool
    public var url: URL
    public var comment: String
    /// A copy 250 pixels wide, if the archive made one.
    public var thumbnailURL: URL?

    public init(
        id: String, types: [String], isFront: Bool, isBack: Bool, url: URL, comment: String, thumbnailURL: URL? = nil
    ) {
        self.id = id
        self.types = types
        self.isFront = isFront
        self.isBack = isBack
        self.url = url
        self.comment = comment
        self.thumbnailURL = thumbnailURL
    }

    /// The sleeve for a disc of a box set whose discs have their own: a front image (not the
    /// main front) whose comment names the disc, as "(Mediums 1–2)". Nil if none does.
    public static func sleeve(forDisc position: Int, in images: [CoverArtImage]) -> CoverArtImage? {
        images.first { !$0.isFront && $0.types.contains("Front") && $0.mediums?.contains(position) == true }
    }

    /// The main front, then the images that name the disc, then the rest, so that a box set's
    /// dozens of images show (and load) the disc's own early; each part keeps the archive's order.
    public static func ordered(_ images: [CoverArtImage], forDisc position: Int?) -> [CoverArtImage] {
        guard let position else { return images }
        func rank(_ image: CoverArtImage) -> Int {
            image.isFront ? 0 : image.mediums?.contains(position) == true ? 1 : 2
        }
        return images.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// Which sleeve each disc takes, for `positions` (the release's CDs): the sleeve's discs,
    /// in the archive's order, and the discs that no sleeve names, which keep the set's cover.
    public static func sleeves(
        for positions: [Int], in images: [CoverArtImage]
    ) -> (sleeves: [(image: CoverArtImage, discs: [Int])], others: [Int]) {
        var sleeves = [(image: CoverArtImage, discs: [Int])]()
        var others = [Int]()
        for position in positions {
            guard let sleeve = sleeve(forDisc: position, in: images) else {
                others.append(position)
                continue
            }
            if let index = sleeves.firstIndex(where: { $0.image.id == sleeve.id }) {
                sleeves[index].discs.append(position)
            } else {
                sleeves.append((sleeve, [position]))
            }
        }
        return (sleeves, others)
    }

    /// The discs that the image's comment names, as editors write them for a box set's sleeves:
    /// 1...2 for "(Mediums 1–2)", 3...3 for "Disc 3". Nil if it names none.
    public var mediums: ClosedRange<Int>? {
        let pattern = /(?i)\b(?:mediums?|discs?|cds?)\s+(\d+)(?:\s*[-–—]\s*(\d+))?/
        guard let match = comment.firstMatch(of: pattern), let first = Int(match.1) else { return nil }
        let last = match.2.flatMap { Int($0) } ?? first
        return first <= last ? first...last : nil
    }

    /// File names, with no extension, for images: the first type in lowercase, such as
    /// "back", with "-01", "-02", and so on when more than one image has that type.
    public static func fileNames(for images: [CoverArtImage]) -> [String] {
        let kinds = images.map { ($0.types.first ?? "other").lowercased().replacingOccurrences(of: " ", with: "-") }
        var seen = [String: Int]()
        return kinds.map { kind in
            guard kinds.filter({ $0 == kind }).count > 1 else { return kind }
            seen[kind, default: 0] += 1
            return kind + String(format: "-%02d", seen[kind]!)
        }
    }
}
