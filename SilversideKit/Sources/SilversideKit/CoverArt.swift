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

public enum CoverArtError: Error, Equatable, CustomStringConvertible {
    case unknownFormat
    case malformedListing

    public var description: String {
        switch self {
        case .unknownFormat: "The cover image is not a JPEG or PNG file."
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

    /// One image, at the size it was uploaded.
    public func download(_ image: CoverArtImage) async throws -> CoverImage? {
        try await client.data(from: image.url).map(CoverImage.init)
    }

    static func images(fromJSON data: Data) throws -> [CoverArtImage] {
        struct Listing: Decodable {
            struct Image: Decodable {
                var id: AnyID
                var types: [String]?
                var front: Bool?
                var back: Bool?
                var image: String
                var comment: String?
            }
            var images: [Image]
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
        return listing.images.compactMap { image in
            // The archive's links are http; the same files are served over https.
            guard var components = URLComponents(string: image.image) else { return nil }
            components.scheme = "https"
            guard let url = components.url else { return nil }
            return CoverArtImage(
                id: image.id.text, types: image.types ?? [], isFront: image.front ?? false,
                isBack: image.back ?? false, url: url, comment: image.comment ?? "")
        }
    }

    /// Saves the release's artwork in `folder`: the front cover as "cover.jpg" (or .png),
    /// and, if `all`, the other images in "Artwork" (see `CoverArtImage.fileNames`).
    /// Returns the files written.
    public func save(releaseID: String, in folder: URL, all: Bool) async throws -> [URL] {
        let images = try await images(releaseID: releaseID)
        var written = [URL]()
        if let front = images.first(where: \.isFront), let image = try await download(front) {
            written.append(try image.write(to: folder))
        }
        guard all else { return written }
        // The other images, three at a time: full-size scans are many megabytes each, and the
        // web client still spaces the requests as the archive asks. The files keep the archive's order.
        let others = Array(
            zip(images.filter { !$0.isFront }, CoverArtImage.fileNames(for: images.filter { !$0.isFront })))
        let artwork = folder.appending(path: "Artwork")
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
        return written + saved.compactMap { $0 }
    }
}

/// One image in the Cover Art Archive.
public struct CoverArtImage: Equatable, Sendable {
    public var id: String
    /// "Front", "Back", "Booklet", "Medium", "Tray", "Obi", "Spine", "Track", "Liner", "Sticker", and so on.
    public var types: [String]
    public var isFront: Bool
    public var isBack: Bool
    public var url: URL
    public var comment: String

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
