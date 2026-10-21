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

    /// Writes the image as "cover.jpg" or "cover.png" in `folder`, and returns the file.
    @discardableResult
    public func write(to folder: URL) throws -> URL {
        guard let fileExtension else { throw CoverArtError.unknownFormat }
        let url = folder.appending(path: "cover.\(fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }
}

public enum CoverArtError: Error, Equatable, CustomStringConvertible {
    case unknownFormat

    public var description: String {
        switch self {
        case .unknownFormat: "The cover image is not a JPEG or PNG file."
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
}
