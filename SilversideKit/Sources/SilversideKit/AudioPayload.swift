import CryptoKit
import Foundation

/// A fingerprint of an audio file's encoded audio, apart from its tags: two files with the same
/// fingerprint hold the same audio bytes, where the file's own index finds them. A change of
/// tags must leave it as it was; `LibraryAlbum`'s writes check it before a file is replaced,
/// and again after.
///
/// - FLAC: the frames after the metadata blocks, and every block but the tags (Vorbis comments,
///   pictures) and padding: STREAMINFO, SEEKTABLE, and so on.
/// - MP4: the contents of each `mdat`, and where each chunk offset (`stco`, `co64`) points in
///   them: which `mdat`, and how far in. New tags move the audio, and the offsets with it. And
///   moov's atoms but `udta` (the tags), with the offsets' values left out: the tracks' sample
///   tables (`stsz`, `stts`, `stsc`), which say how to read the audio.
public enum AudioPayload {
    public static func fingerprint(of data: Data, kind: AudioFileKind) throws -> Data {
        switch kind {
        case .flac:
            let (blocks, audioStart) = try FLACTags.parseBlocks(data)
            var hash = SHA256()
            for block in blocks where ![1, 4, 6].contains(block.type) {
                hash.update(data: [block.type])
                hash.update(data: block.body)
            }
            hash.update(data: data[audioStart...])
            return Data(hash.finalize())
        case .mp4:
            return try mp4Fingerprint(data)
        case .other:
            throw AudioPayloadError.unsupported
        }
    }

    public static func fingerprint(of url: URL, kind: AudioFileKind) throws -> Data {
        try fingerprint(of: Data(contentsOf: url, options: .alwaysMapped), kind: kind)
    }

    private static func mp4Fingerprint(_ data: Data) throws -> Data {
        let top = try MP4Tags.atoms(in: data, data.startIndex..<data.endIndex)
        let mdats = top.filter { $0.type == "mdat" }
        guard let moov = top.first(where: { $0.type == "moov" }), !mdats.isEmpty else { throw MP4Error.malformed }
        var hash = SHA256()
        for mdat in mdats { hash.update(data: data[mdat.body]) }
        // moov's atoms but the tags, with the offsets' values as zeros: they move with the audio.
        let positions = try offsetPositions(in: data, moov.body)
        for child in try MP4Tags.atoms(in: data, moov.body) where child.type != "udta" {
            var copy = Data(data[child.range])
            for (position, width) in positions where child.range.contains(position) {
                let start = copy.startIndex + (position - child.range.lowerBound)
                copy.replaceSubrange(start..<(start + width), with: Data(count: width))
            }
            hash.update(data: copy)
        }
        // Each chunk offset, as its mdat's index and the distance from that mdat's contents.
        for offset in try chunkOffsets(in: data, moov.body) {
            guard let index = mdats.firstIndex(where: { $0.body.contains(offset) })
            else { throw AudioPayloadError.offsetOutsideAudio }
            // The two numbers' bytes, not the array's: withUnsafeBytes(of:) on an array gives its pointer.
            let place = [Int64(index), Int64(offset - mdats[index].body.lowerBound)]
            place.withUnsafeBytes { hash.update(bufferPointer: $0) }
        }
        return Data(hash.finalize())
    }

    /// Every chunk offset in moov's tracks, as a position in `data`.
    private static func chunkOffsets(in data: Data, _ range: Range<Int>) throws -> [Int] {
        try offsetPositions(in: data, range).map { position, width in
            let value =
                width == 8
                ? Int(MP4Tags.uint32(data, position)) << 32 | Int(MP4Tags.uint32(data, position + 4))
                : Int(MP4Tags.uint32(data, position))
            return data.startIndex + value
        }
    }

    /// Where each chunk offset's value is in `data`, and its width (4 for stco, 8 for co64).
    private static func offsetPositions(in data: Data, _ range: Range<Int>) throws -> [(Int, Int)] {
        var positions = [(Int, Int)]()
        for child in try MP4Tags.atoms(in: data, range) {
            switch child.type {
            case "trak", "mdia", "minf", "stbl":
                positions += try offsetPositions(in: data, child.body)
            case "stco", "co64":
                let width = child.type == "co64" ? 8 : 4
                guard child.body.count >= 8 else { throw MP4Error.malformed }
                let count = Int(MP4Tags.uint32(data, child.body.lowerBound + 4))
                guard child.body.count >= 8 + count * width else { throw MP4Error.malformed }
                for index in 0..<count { positions.append((child.body.lowerBound + 8 + index * width, width)) }
            default:
                break
            }
        }
        return positions
    }
}

/// The audio files whose tags Silverside can change in place.
public enum AudioFileKind: Equatable, Sendable {
    case flac
    /// Apple Lossless or AAC in .m4a.
    case mp4
    /// Any other audio file (MP3, AIFF, WAV, ...), which Silverside reads but does not change yet.
    case other

    public init(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "flac": self = .flac
        case "m4a", "mp4", "m4b": self = .mp4
        default: self = .other
        }
    }
}

public enum AudioPayloadError: Error, Equatable, CustomStringConvertible {
    case unsupported
    case offsetOutsideAudio
    case changed(URL)

    public var description: String {
        switch self {
        case .unsupported: "Silverside cannot change this kind of file yet."
        case .offsetOutsideAudio: "The file's index points outside its audio."
        case .changed(let url): "The audio of \(url.lastPathComponent) would change, so the file was left as it was."
        }
    }
}
