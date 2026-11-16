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
        /// The audio's format, if AudioToolbox reads the file.
        public var format: Format?
        /// The file's size.
        public var bytes = 0
        /// True for a FLAC file with an ID3v2 tag before its FLAC data, as Exact Audio Copy
        /// writes one (`FLACTags.leadingID3Size`). A write of the file leaves it out.
        public var hasLeadingID3 = false

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

    /// An audio file's format: "FLAC, 44.1 kHz, 16 bits, stereo".
    public struct Format: Equatable, Sendable {
        /// "FLAC", "ALAC", "AAC", "MP3", "AIFF", "WAV", or the format's code.
        public var name: String
        public var sampleRate: Double
        public var channels: Int
        /// The bits of a lossless file or PCM; nil for a lossy one.
        public var bits: Int?
        /// The average bit rate, in bits a second, if the file gives it.
        public var bitRate: Int?
        public var isLossless: Bool { !["AAC", "MP3", "Opus"].contains(name) }

        /// "FLAC, 44.1 kHz, 16 bits, stereo", "AAC, 44.1 kHz, 256 kb/s, stereo".
        public var summary: String {
            var parts = [name]
            let kilohertz = sampleRate / 1000
            parts.append(
                (kilohertz == kilohertz.rounded() ? String(Int(kilohertz)) : String(format: "%.1f", kilohertz)) + " kHz"
            )
            if let bits, isLossless { parts.append("\(bits) bits") }
            if !isLossless, let bitRate { parts.append("\(bitRate / 1000) kb/s") }
            parts.append(channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(channels) channels")
            return parts.joined(separator: ", ")
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
    /// cover.jpg or cover.png, if the folder has one, else folder.jpg (or .png), as many
    /// players and Windows name it.
    public var coverFile: URL?
    public var coverPicture: Picture?
    /// The images in the folder's Artwork.
    public var artworkCount: Int
    /// The choices kept in the folder by an earlier run.
    public var choice: AlbumChoice?

    /// Reads the folder: the audio files directly in it (not in subfolders), and its covers.
    public static func read(_ folder: URL) throws -> LibraryAlbum {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let urls = names.filter { !$0.hasPrefix(".") }.map { folder.appending(path: $0) }
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        return read(urls, in: folder)
    }

    /// Reads these files of `folder` (with the folder's covers and choice), as a summary of
    /// some files does.
    public static func read(_ urls: [URL], in folder: URL) -> LibraryAlbum {
        var files = urls.map(readFile)
        files.sort { a, b in
            let left = (a.discNumber ?? 1, a.trackNumber ?? Int.max)
            let right = (b.discNumber ?? 1, b.trackNumber ?? Int.max)
            if left != right { return left < right }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        // The order that an earlier run paired with the release's tracks, while the folder has
        // the same files: a run that wrote some files' track numbers and not others' (one was
        // in use) would sort them otherwise, and pair them with the wrong tracks.
        let choice = AlbumChoice.read(in: folder)
        if let order = choice?.files, order.count == files.count,
            Set(order) == Set(files.map(\.url.lastPathComponent))
        {
            let place = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            files.sort { place[$0.url.lastPathComponent, default: 0] < place[$1.url.lastPathComponent, default: 0] }
        }
        let coverFile = CoverFiles.album(in: folder) ?? folderImage(in: folder)
        return LibraryAlbum(
            folder: folder, files: files, coverFile: coverFile,
            coverPicture: coverFile.flatMap { try? Data(contentsOf: $0) }.map(Picture.init),
            artworkCount: ArtworkFolder.count(in: folder), choice: choice)
    }

    /// The folder's folder.jpg, Folder.jpg, or folder.png, by its name on disk.
    static func folderImage(in folder: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let image = names.sorted().first { ["folder.jpg", "folder.jpeg", "folder.png"].contains($0.lowercased()) }
        return image.map { folder.appending(path: $0) }
    }

    static func readFile(_ url: URL) -> File {
        let kind = AudioFileKind(fileExtension: url.pathExtension)
        let details = AudioDetails.read(url)
        var tags = [(key: String, value: String)]()
        var cover: Data?
        var canWriteCover = kind != .other
        switch kind {
        case .flac:
            tags = (try? FLACTags.read(url)) ?? []
            cover = try? FLACTags.readFrontCover(url)
        case .mp4:
            if let read = try? MP4Tags.read(url, every: true) {
                // A total or a disc number of 0 in trkn and disk means none.
                tags = read.comments.filter {
                    !(["TRACKTOTAL", "DISCTOTAL", "DISCNUMBER"].contains($0.key) && $0.value == "0")
                }
                cover = read.cover
            }
            if let data = try? Data(contentsOf: url, options: .alwaysMapped),
                let top = try? MP4Tags.atoms(in: data, data.startIndex..<data.endIndex),
                let moov = top.first(where: { $0.type == "moov" }),
                let handler = try? MP4Tags.metaHandler(in: data, moov: moov), handler != "mdir"
            {
                canWriteCover = false
            }
        case .other:
            // MP3: its ID3v2 tag; else what macOS reads of the file's tags (ID3v2.2, AIFF, WAV, ...).
            if let read = (try? ID3Tags.read(url)) ?? nil {
                (tags, cover) = (read.comments, read.cover)
            } else if let details {
                (tags, cover) = (details.info, details.artwork)
            }
        }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return File(
            url: url, kind: kind, milliseconds: details?.milliseconds, tags: tags, cover: cover.map(Picture.init),
            canWriteCover: canWriteCover, format: details?.format, bytes: bytes,
            hasLeadingID3: kind == .flac && FLACTags.hasLeadingID3(url))
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
    /// The release's media that the files are, in order (`AlbumFit.media`), when tags were written.
    public var media: [Int]?
    /// The album name that the user gave the tags, where it differs from the release's.
    public var album: String?
    /// The files' names, in the order that was paired with the release's tracks, when tags were written.
    public var files: [String]?
    /// True when the files were paired with the release's tracks by their order (`--force-fit`),
    /// because MusicBrainz has no lengths or some do not agree: a later run pairs them so again.
    public var byOrder: Bool?
    /// True when the cover is an image file of the user's (`--front` with a file), not an
    /// image of the Cover Art Archive: the folder's cover file stays the cover.
    public var ownCover: Bool?
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
        for key in ["release", "frontImageID", "artworkImageIDs", "media", "album", "files", "byOrder", "ownCover"]
        where object[key] == nil {
            object[key] = NSNull()
        }
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

/// What AudioToolbox reads of an audio file: its length and format, and for files whose tags
/// Silverside does not read itself, the common tags and the cover (`kAudioFilePropertyInfoDictionary`,
/// `kAudioFilePropertyAlbumArtwork`).
struct AudioDetails {
    var milliseconds: Int?
    var format: LibraryAlbum.Format
    var info: [(key: String, value: String)]
    var artwork: Data?

    /// AudioToolbox's names for the tags, and the Vorbis comment keys a summary shows them as.
    static let infoKeys: [String: String] = [
        "title": "TITLE", "artist": "ARTIST", "album": "ALBUM", "track number": "TRACKNUMBER", "year": "DATE",
        "genre": "GENRE", "comments": "COMMENT", "composer": "COMPOSER", "lyricist": "LYRICIST",
        "copyright": "COPYRIGHT", "encoding application": "ENCODER", "recorded date": "RECORDEDDATE", "ISRC": "ISRC",
        "tempo": "BPM", "key signature": "KEY", "subtitle": "SUBTITLE", "conductor": "CONDUCTOR",
    ]

    static func read(_ url: URL) -> AudioDetails? {
        var file: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let file else { return nil }
        defer { ExtAudioFileDispose(file) }
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &description) == noErr,
            description.mSampleRate > 0
        else { return nil }
        var frames: Int64 = 0
        size = UInt32(MemoryLayout<Int64>.size)
        let milliseconds =
            ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames) == noErr
            ? Int((Double(frames) * 1000 / description.mSampleRate).rounded()) : nil

        var audioFile: AudioFileID?
        size = UInt32(MemoryLayout<AudioFileID?>.size)
        _ = ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioFile, &size, &audioFile)
        func uint32(_ property: AudioFilePropertyID) -> UInt32? {
            guard let audioFile else { return nil }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioFileGetProperty(audioFile, property, &size, &value) == noErr ? value : nil
        }
        let name: String
        switch description.mFormatID {
        case kAudioFormatFLAC: name = "FLAC"
        case kAudioFormatAppleLossless: name = "ALAC"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD:
            name = "AAC"
        case kAudioFormatMPEGLayer3: name = "MP3"
        case kAudioFormatOpus: name = "Opus"
        case kAudioFormatLinearPCM:
            switch url.pathExtension.lowercased() {
            case "aif", "aiff": name = "AIFF"
            case "wav": name = "WAV"
            default: name = "PCM"
            }
        default:
            name = withUnsafeBytes(of: description.mFormatID.bigEndian) { String(decoding: $0, as: UTF8.self) }
        }
        var bits = description.mBitsPerChannel > 0 ? Int(description.mBitsPerChannel) : nil
        if bits == nil, let source = uint32(kAudioFilePropertySourceBitDepth), Int32(bitPattern: source) > 0 {
            bits = Int(source)
        }
        let format = LibraryAlbum.Format(
            name: name, sampleRate: description.mSampleRate, channels: Int(description.mChannelsPerFrame), bits: bits,
            bitRate: uint32(kAudioFilePropertyBitRate).map(Int.init).flatMap { $0 > 0 ? $0 : nil })

        var info = [(key: String, value: String)]()
        var artwork: Data?
        if let audioFile {
            var dictionary: Unmanaged<CFDictionary>?
            var size = UInt32(MemoryLayout<CFDictionary?>.size)
            if AudioFileGetProperty(audioFile, kAudioFilePropertyInfoDictionary, &size, &dictionary) == noErr,
                let values = dictionary?.takeRetainedValue() as? [String: Any]
            {
                for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                    guard key != "approximate duration in seconds", key != "source bit depth",
                        key != "channel layout", key != "nominal bit rate"
                    else { continue }
                    info.append((infoKeys[key] ?? key.uppercased(), "\(value)"))
                }
            }
            var picture: Unmanaged<CFData>?
            size = UInt32(MemoryLayout<CFData?>.size)
            if AudioFileGetProperty(audioFile, kAudioFilePropertyAlbumArtwork, &size, &picture) == noErr {
                artwork = picture?.takeRetainedValue() as Data?
            }
        }
        return AudioDetails(milliseconds: milliseconds, format: format, info: info, artwork: artwork)
    }
}

extension LibraryAlbum {
    /// The folder's tags for a summary (`silverside tags`): the ones that every file has with the
    /// same values, once, and each file's others. Keys are compared without case, as Vorbis
    /// comments are, and shown as the first file that has one writes it.
    public struct TagSummary: Sendable {
        public struct Tag: Equatable, Sendable {
            public var key: String
            public var values: [String]
        }

        /// Tags with the same values in every file, in the first file's order.
        public var shared: [Tag]
        /// Each file's other tags, in its order.
        public var files: [[Tag]]
        /// The keys left out (`technicalKeys`), with how many files have each.
        public var hidden: [(key: String, files: Int)]
    }

    /// Items that players and encoders keep for themselves, which a summary leaves out unless
    /// asked: iTunes's gapless playback and volume data, and CDDB IDs.
    public static let technicalKeys: Set<String> = [
        "ITUNSMPB", "ITUNNORM", "ITUNPGAP", "ITUNES_CDDB_IDS", "ITUNES_CDDB_1", "ITUNES_CDDB_TRACKNUMBER",
        "ENCODING PARAMS", "GAPLESS",
    ]

    /// The summary; without `technical`, the `technicalKeys` are only counted.
    public func tagSummary(technical: Bool = false) -> TagSummary {
        var hidden = [(key: String, files: Int)]()
        func grouped(_ tags: [(key: String, value: String)]) -> [TagSummary.Tag] {
            var result = [TagSummary.Tag]()
            var hiddenHere = Set<String>()
            for (key, value) in tags {
                let folded = key.uppercased()
                if !technical, Self.technicalKeys.contains(folded) {
                    if hiddenHere.insert(folded).inserted {
                        if let index = hidden.firstIndex(where: { $0.key.uppercased() == folded }) {
                            hidden[index].files += 1
                        } else {
                            hidden.append((key, 1))
                        }
                    }
                    continue
                }
                if let index = result.firstIndex(where: { $0.key.uppercased() == folded }) {
                    result[index].values.append(value)
                } else {
                    result.append(TagSummary.Tag(key: key, values: [value]))
                }
            }
            return result
        }
        let tags = files.map { grouped($0.tags) }
        func same(_ a: TagSummary.Tag, _ b: TagSummary.Tag) -> Bool {
            a.key.uppercased() == b.key.uppercased() && a.values == b.values
        }
        guard let first = tags.first else { return TagSummary(shared: [], files: [], hidden: hidden) }
        // With one file, nothing is shared: its tags are its own.
        let shared =
            tags.count > 1 ? first.filter { tag in tags.allSatisfy { $0.contains { same($0, tag) } } } : []
        return TagSummary(
            shared: shared, files: tags.map { $0.filter { tag in !shared.contains { same($0, tag) } } },
            hidden: hidden)
    }

    /// The folders under `folder` (and it) that hold audio files, in order, for a summary of a
    /// library's folders.
    public static func audioFolders(under folder: URL) -> [URL] {
        let manager = FileManager.default
        var found = [URL]()
        func visit(_ url: URL) {
            guard let names = try? manager.contentsOfDirectory(atPath: url.path) else { return }
            let visible = names.filter { !$0.hasPrefix(".") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if visible.contains(where: { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) {
                found.append(url)
            }
            for name in visible {
                let child = url.appending(path: name, directoryHint: .isDirectory)
                var isFolder: ObjCBool = false
                if manager.fileExists(atPath: child.path, isDirectory: &isFolder), isFolder.boolValue { visit(child) }
            }
        }
        visit(folder)
        return found
    }
}
