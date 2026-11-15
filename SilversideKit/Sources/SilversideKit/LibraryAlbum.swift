import AudioToolbox
import CryptoKit
import Foundation
import ImageIO

/// An album folder that Silverside did not rip, as `silverside album` sees it: its audio files
/// in order, with their lengths, tags, and embedded covers; its cover file and Artwork folder;
/// and the choices kept in it (`AlbumChoice`). One folder is one release: a single disc, or
/// every disc of a set with their disc numbers in the tags.
public struct LibraryAlbum: Sendable {
    public struct File: Sendable {
        public var url: URL
        public var kind: AudioFileKind
        /// The length in milliseconds; nil if AudioToolbox cannot read the file.
        public var milliseconds: Int?
        /// The tags as Vorbis comment keys (`MP4Tags` maps iTunes atoms to them). Empty for a
        /// kind that Silverside does not read the tags of.
        public var tags: [(key: String, value: String)]
        /// The embedded front cover, if the file has one.
        public var cover: Picture?
        /// False for a file whose cover Silverside cannot write: a kind it does not change yet,
        /// or an MP4 file whose tags are not iTunes's (`MP4Error.otherTags`).
        public var canWriteCover = true

        /// The first value of a tag.
        public func tag(_ key: String) -> String? {
            tags.first { $0.key.uppercased() == key }?.value
        }

        /// The disc number from DISCNUMBER ("2" or "2/4").
        public var discNumber: Int? { tag("DISCNUMBER").flatMap(Self.leadingNumber) }
        /// The track number from TRACKNUMBER ("3" or "3/12").
        public var trackNumber: Int? { tag("TRACKNUMBER").flatMap(Self.leadingNumber) }

        static func leadingNumber(_ text: String) -> Int? {
            Int(text.prefix { $0.isASCII && $0.isNumber })
        }
    }

    /// An image in a file or a folder: its size and format.
    public struct Picture: Equatable, Sendable {
        public var bytes: Int
        public var width: Int?
        public var height: Int?
        /// "JPEG", "PNG", and so on.
        public var format: String?
        /// SHA-256 of the image's bytes, to tell whether two are the same.
        public var fingerprint: Data
        /// The picture as 16 × 16 gray values, to tell the same picture in another encoding.
        var signature: [UInt8]

        public init(data: Data) {
            bytes = data.count
            fingerprint = Data(SHA256.hash(data: data))
            let source = CGImageSourceCreateWithData(data as CFData, nil)
            let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            width = properties?[kCGImagePropertyPixelWidth] as? Int
            height = properties?[kCGImagePropertyPixelHeight] as? Int
            format = Self.format(of: data)
            signature = source.map(Self.signature) ?? []
        }

        /// True if `other` is this picture: the same bytes, or the same size and nearly the same
        /// pixels, as when another program saved the same image as a JPEG of its own.
        public func isSamePicture(as other: Picture) -> Bool {
            if fingerprint == other.fingerprint { return true }
            guard let width, let height, width == other.width, height == other.height, !signature.isEmpty,
                signature.count == other.signature.count
            else { return false }
            let difference = zip(signature, other.signature).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            // On average within 2 of 255: JPEG at another quality, not another picture.
            return difference <= 2 * signature.count
        }

        static func signature(_ source: CGImageSource) -> [UInt8] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return [] }
            var pixels = [UInt8](repeating: 0, count: 16 * 16)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard
                    let context = CGContext(
                        data: buffer.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
                else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
                return true
            }
            return drawn ? pixels : []
        }

        static func format(of data: Data) -> String? {
            switch ArtworkFile.fileExtension(of: data) {
            case "jpg": "JPEG"
            case "png": "PNG"
            case "gif": "GIF"
            case "pdf": "PDF"
            case "webp": "WebP"
            case "tif": "TIFF"
            default: nil
            }
        }

        /// "1000 × 1000 JPEG, 312 KB".
        public var summary: String {
            let size = width.flatMap { width in height.map { "\(width) × \($0)" } }
            return [size, format].compactMap { $0 }.joined(separator: " ") + ", " + Self.bytes(bytes)
        }

        /// "312 KB", "4.2 MB".
        public static func bytes(_ count: Int) -> String {
            count < 1_000_000 ? "\(max(1, count / 1000)) KB" : String(format: "%.1f MB", Double(count) / 1_000_000)
        }
    }

    public static let audioExtensions: Set<String> = [
        "flac", "m4a", "mp4", "m4b", "mp3", "aif", "aiff", "wav", "aac", "ogg", "opus", "wv", "ape", "dsf", "dff",
    ]

    public var folder: URL
    /// The audio files, in disc and track order (from the tags), then by name.
    public var files: [File]
    /// cover.jpg or cover.png, if the folder has one.
    public var coverFile: URL?
    public var coverPicture: Picture?
    /// The images in the folder's Artwork.
    public var artworkCount: Int
    /// The choices kept in the folder by an earlier run.
    public var choice: AlbumChoice?

    /// Reads the folder: the audio files directly in it (not in subfolders), and its covers.
    public static func read(_ folder: URL) throws -> LibraryAlbum {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        var files = [File]()
        for name in names where !name.hasPrefix(".") {
            let url = folder.appending(path: name)
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            files.append(readFile(url))
        }
        files.sort { a, b in
            let left = (a.discNumber ?? 1, a.trackNumber ?? Int.max)
            let right = (b.discNumber ?? 1, b.trackNumber ?? Int.max)
            if left != right { return left < right }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        let coverFile = CoverFiles.album(in: folder)
        return LibraryAlbum(
            folder: folder, files: files, coverFile: coverFile,
            coverPicture: coverFile.flatMap { try? Data(contentsOf: $0) }.map(Picture.init),
            artworkCount: ArtworkFolder.count(in: folder), choice: AlbumChoice.read(in: folder))
    }

    static func readFile(_ url: URL) -> File {
        let kind = AudioFileKind(fileExtension: url.pathExtension)
        var tags = [(key: String, value: String)]()
        var cover: Data?
        var canWriteCover = kind != .other
        switch kind {
        case .flac:
            tags = (try? FLACTags.read(url)) ?? []
            cover = try? FLACTags.readFrontCover(url)
        case .mp4:
            if let read = try? MP4Tags.read(url) { (tags, cover) = (read.comments, read.cover) }
            if let data = try? Data(contentsOf: url, options: .alwaysMapped),
                let top = try? MP4Tags.atoms(in: data, data.startIndex..<data.endIndex),
                let moov = top.first(where: { $0.type == "moov" }),
                let handler = try? MP4Tags.metaHandler(in: data, moov: moov), handler != "mdir"
            {
                canWriteCover = false
            }
        case .other:
            break
        }
        return File(
            url: url, kind: kind, milliseconds: milliseconds(of: url), tags: tags, cover: cover.map(Picture.init),
            canWriteCover: canWriteCover)
    }

    /// The file's length, from its frame count and sample rate.
    static func milliseconds(of url: URL) -> Int? {
        var file: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let file else { return nil }
        defer { ExtAudioFileDispose(file) }
        var frames: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames) == noErr else {
            return nil
        }
        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format) == noErr,
            format.mSampleRate > 0
        else { return nil }
        return Int((Double(frames) * 1000 / format.mSampleRate).rounded())
    }

    /// The files' lengths, in order.
    public var lengths: [Int?] { files.map(\.milliseconds) }

    /// The value of a tag that most files that have it share, or nil if none has it.
    public func commonTag(_ key: String) -> String? {
        let values = files.compactMap { $0.tag(key) }.filter { !$0.isEmpty }
        let counts = Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// The files' release ID (MUSICBRAINZ_ALBUMID, as Picard writes it), if every file that
    /// has one has the same.
    public var taggedReleaseID: String? {
        let ids = Set(files.compactMap { $0.tag("MUSICBRAINZ_ALBUMID") }.filter { !$0.isEmpty })
        return ids.count == 1 ? ids.first : nil
    }
}

/// The choices that `silverside album` keeps in an album folder, so that a later run finds
/// the same release and images: ".silverside-album.json". Keys that this version does not
/// know are kept when it saves (`JSONMerge`).
public struct AlbumChoice: Codable, Equatable, Sendable {
    public static let fileName = ".silverside-album.json"

    public var releaseID: String
    /// "The Beatles - Abbey Road", for people who open the file.
    public var release: String?
    /// The Cover Art Archive image used as the cover.
    public var frontImageID: String?
    /// The images saved in Artwork, in order; nil if none were chosen.
    public var artworkImageIDs: [String]?
    public var updated: Date
    /// "Silverside 0.9.8 (abc1234)".
    public var program: String

    public init(
        releaseID: String, release: String? = nil, frontImageID: String? = nil, artworkImageIDs: [String]? = nil,
        updated: Date = Date(), program: String = SilversideVersion.program
    ) {
        self.releaseID = releaseID
        self.release = release
        self.frontImageID = frontImageID
        self.artworkImageIDs = artworkImageIDs
        self.updated = Date(timeIntervalSince1970: updated.timeIntervalSince1970.rounded(.down))
        self.program = program
    }

    public static func read(in folder: URL) -> AlbumChoice? {
        guard let data = try? Data(contentsOf: folder.appending(path: fileName)) else { return nil }
        return try? decoder.decode(AlbumChoice.self, from: data)
    }

    public func save(in folder: URL) throws {
        let url = folder.appending(path: Self.fileName)
        let file = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        var object = try JSONSerialization.jsonObject(with: Self.encoder.encode(self)) as? [String: Any] ?? [:]
        // Optional values as null, so that clearing one clears it in the file too.
        for key in ["release", "frontImageID", "artworkImageIDs"] where object[key] == nil { object[key] = NSNull() }
        let merged = JSONMerge.overlay(object, on: file)
        try JSONSerialization.data(
            withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        .write(to: url, options: .atomic)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Artwork files as the Cover Art Archive serves them: JPEG and PNG mostly, but also GIF,
/// PDF, WebP, and TIFF, which Artwork keeps as they are.
public enum ArtworkFile {
    /// The extension for the file's format, from its first bytes; nil if it is none of these.
    public static func fileExtension(of data: Data) -> String? {
        if let tagged = CoverImage(data: data).fileExtension { return tagged }
        if data.starts(with: Array("GIF8".utf8)) { return "gif" }
        if data.starts(with: Array("%PDF".utf8)) { return "pdf" }
        if data.count >= 12, data.starts(with: Array("RIFF".utf8)),
            data[data.startIndex + 8..<data.startIndex + 12] == Data("WEBP".utf8)
        {
            return "webp"
        }
        if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "tif" }
        return nil
    }

    /// Writes an image as "<name>.<extension>" in `folder`, with the extension of its format,
    /// else of `url`'s path. Returns the file.
    @discardableResult
    static func write(_ data: Data, name: String, in folder: URL, from url: URL) throws -> URL {
        let fileExtension =
            fileExtension(of: data) ?? (url.pathExtension.isEmpty ? "bin" : url.pathExtension.lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(name).\(fileExtension)")
        try data.write(to: file, options: .atomic)
        return file
    }
}
