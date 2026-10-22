import Foundation

/// Writes the tags of a FLAC file: Vorbis comments and a front cover PICTURE block.
///
/// Apple's encoder writes STREAMINFO and a small VORBIS_COMMENT block, with no padding.
/// The writer keeps STREAMINFO and any other blocks (such as SEEKTABLE), puts in its own
/// VORBIS_COMMENT and PICTURE, adds padding so that tags can change later without a new
/// file, and copies the audio frames unchanged.
public enum FLACTags {
    public static let vendor = "Silverside \(CDRipVersion.string)"

    /// Padding after the tags, for later edits.
    static let paddingBytes = 8192

    enum BlockType: UInt8 {
        case streamInfo = 0
        case padding = 1
        case vorbisComment = 4
        case picture = 6
    }

    /// Replaces the file's tags.
    public static func write(_ comments: [(key: String, value: String)], cover: EmbeddedCover?, to url: URL) throws {
        let data = try Data(contentsOf: url)
        let (blocks, audioStart) = try parseBlocks(data)
        guard let streamInfo = blocks.first, streamInfo.type == BlockType.streamInfo.rawValue else {
            throw FLACError.malformed
        }
        // Keep STREAMINFO first, then any blocks that are not tags or padding.
        let replaced: Set<UInt8> = [
            BlockType.padding.rawValue, BlockType.vorbisComment.rawValue, BlockType.picture.rawValue,
        ]
        var kept = blocks.filter { !replaced.contains($0.type) }
        kept.append((BlockType.vorbisComment.rawValue, vorbisComment(comments)))
        if let cover { kept.append((BlockType.picture.rawValue, try picture(cover))) }
        kept.append((BlockType.padding.rawValue, Data(count: paddingBytes)))

        var output = Data("fLaC".utf8)
        for (index, block) in kept.enumerated() {
            guard block.body.count < 1 << 24 else { throw FLACError.blockTooLarge }
            let last: UInt8 = index == kept.count - 1 ? 0x80 : 0
            output.append(last | block.type)
            output.append(contentsOf: [
                UInt8(block.body.count >> 16 & 0xFF), UInt8(block.body.count >> 8 & 0xFF),
                UInt8(block.body.count & 0xFF),
            ])
            output.append(block.body)
        }
        output.append(data[audioStart...])
        try output.write(to: url, options: .atomic)
    }

    /// The file's Vorbis comments, in order.
    public static func read(_ url: URL) throws -> [(key: String, value: String)] {
        let (blocks, _) = try parseBlocks(try Data(contentsOf: url))
        guard let block = blocks.first(where: { $0.type == BlockType.vorbisComment.rawValue }) else { return [] }
        let body = [UInt8](block.body)
        var index = 0
        func uint32() throws -> Int {
            guard index + 4 <= body.count else { throw FLACError.malformed }
            defer { index += 4 }
            return (0..<4).reduce(0) { $0 | Int(body[index + $1]) << (8 * $1) }
        }
        func string() throws -> String {
            let length = try uint32()
            guard index + length <= body.count else { throw FLACError.malformed }
            defer { index += length }
            return String(decoding: body[index..<(index + length)], as: UTF8.self)
        }
        _ = try string()
        return try (0..<uint32()).map { _ in
            let comment = try string()
            let parts = comment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        }
    }

    /// The front cover's image data, if the file has one.
    public static func readFrontCover(_ url: URL) throws -> Data? {
        let (blocks, _) = try parseBlocks(try Data(contentsOf: url))
        for block in blocks where block.type == BlockType.picture.rawValue {
            let body = [UInt8](block.body)
            var index = 0
            func uint32() throws -> Int {
                guard index + 4 <= body.count else { throw FLACError.malformed }
                defer { index += 4 }
                return (0..<4).reduce(0) { $0 << 8 | Int(body[index + $1]) }
            }
            func skip(_ count: Int) throws {
                guard index + count <= body.count else { throw FLACError.malformed }
                index += count
            }
            let type = try uint32()
            try skip(try uint32())  // MIME type
            try skip(try uint32())  // description
            try skip(16)  // width, height, depth, colors
            let length = try uint32()
            guard index + length <= body.count else { throw FLACError.malformed }
            if type == 3 { return Data(body[index..<(index + length)]) }
        }
        return nil
    }

    /// The metadata blocks (type and body), and where the audio frames start.
    static func parseBlocks(_ data: Data) throws -> (blocks: [(type: UInt8, body: Data)], audioStart: Int) {
        let bytes = [UInt8](data.prefix(4))
        guard bytes == Array("fLaC".utf8) else { throw FLACError.malformed }
        var blocks = [(type: UInt8, body: Data)]()
        var index = data.startIndex + 4
        while true {
            guard index + 4 <= data.endIndex else { throw FLACError.malformed }
            let header = data[index]
            let length = Int(data[index + 1]) << 16 | Int(data[index + 2]) << 8 | Int(data[index + 3])
            guard index + 4 + length <= data.endIndex else { throw FLACError.malformed }
            blocks.append((header & 0x7F, data[(index + 4)..<(index + 4 + length)]))
            index += 4 + length
            if header & 0x80 != 0 { return (blocks, index) }
        }
    }

    static func vorbisComment(_ comments: [(key: String, value: String)]) -> Data {
        var body = Data()
        func append(_ text: String) {
            let bytes = Array(text.utf8)
            appendUInt32(bytes.count)
            body.append(contentsOf: bytes)
        }
        func appendUInt32(_ value: Int) {
            body.append(contentsOf: (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) })
        }
        append(vendor)
        appendUInt32(comments.count)
        for comment in comments { append("\(comment.key)=\(comment.value)") }
        return body
    }

    static func picture(_ cover: EmbeddedCover) throws -> Data {
        guard let mime = cover.image.mimeType else { throw CoverArtError.unknownFormat }
        var body = Data()
        func appendUInt32(_ value: Int) {
            body.append(contentsOf: (0..<4).reversed().map { UInt8(value >> (8 * $0) & 0xFF) })
        }
        appendUInt32(3)  // Cover (front)
        appendUInt32(mime.utf8.count)
        body.append(contentsOf: Array(mime.utf8))
        appendUInt32(0)  // no description
        appendUInt32(cover.width)
        appendUInt32(cover.height)
        appendUInt32(24)  // bits per pixel
        appendUInt32(0)  // not an indexed image
        appendUInt32(cover.image.data.count)
        body.append(cover.image.data)
        return body
    }
}

public enum FLACError: Error, Equatable, CustomStringConvertible {
    case malformed
    case blockTooLarge

    public var description: String {
        switch self {
        case .malformed: "The file is not a FLAC file that Silverside can read."
        case .blockTooLarge: "A tag is larger than a FLAC metadata block can hold (16 MB)."
        }
    }
}
