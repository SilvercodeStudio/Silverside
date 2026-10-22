import Foundation

/// Encodes MP3 with the external `lame` program. Apple's frameworks have no MP3 encoder,
/// and running LAME as a separate program keeps its LGPL code out of Silverside. Silverside writes
/// the ID3 tag itself (`ID3Tags`).
public enum MP3Encoder {
    /// The `lame` program: on the PATH, or where Homebrew puts it. Nil if it is not installed.
    public static func lame() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let folders = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return folders.map { URL(filePath: $0).appending(path: "lame") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Writes `samples` to `url` as MP3, through `lame`.
    public static func encode(
        _ samples: [UInt32], to url: URL, lame: URL, options: MP3Options = MP3Options()
    ) throws {
        let process = Process()
        process.executableURL = lame
        process.arguments =
            ["--quiet", "-r", "-s", "44.1", "--bitwidth", "16", "--signed", "--little-endian", "-m", "j"]
            + options.lameArguments + ["-", url.path]
        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardError = errors
        // A write to a pipe whose reader has exited must fail, not end this whole process
        // with SIGPIPE (which Foundation's Pipe does not turn off).
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // Take what lame says as it says it, so that a full pipe can never block it.
        let said = CollectedOutput()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { said.append(data) }
        }
        try process.run()
        // Write the PCM in parts of 1 second, as little-endian bytes.
        let writer = input.fileHandleForWriting
        do {
            for start in stride(from: 0, to: samples.count, by: 44_100) {
                let part = samples[start..<min(start + 44_100, samples.count)]
                try writer.write(contentsOf: part.withUnsafeBytes { Data($0) })
            }
            try writer.close()
        } catch {
            // lame stopped reading, so it has exited or is about to: its message says why.
            try? writer.close()
        }
        process.waitUntilExit()
        errors.fileHandleForReading.readabilityHandler = nil
        said.append(errors.fileHandleForReading.readDataToEndOfFile())
        guard process.terminationStatus == 0 else {
            throw MP3Error.lameFailed(
                status: process.terminationStatus, message: String(decoding: said.data, as: UTF8.self))
        }
    }

    /// What a program wrote to a pipe, collected from any thread.
    private final class CollectedOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var collected = Data()

        func append(_ more: Data) {
            lock.withLock { collected.append(more) }
        }

        var data: Data { lock.withLock { collected } }
    }
}

public enum MP3Error: Error, Equatable, CustomStringConvertible {
    case lameNotFound
    case lameFailed(status: Int32, message: String)
    case malformedID3Tag(URL)

    public var description: String {
        switch self {
        case .lameNotFound: "MP3 needs the lame program (for example: brew install lame)."
        case .lameFailed(let status, let message): "lame failed with status \(status): \(message)"
        case .malformedID3Tag(let url): "\(url.path) has an ID3 tag that Silverside cannot read."
        }
    }
}

/// Writes an ID3v2.4 tag at the start of an MP3 file, in place of any ID3 tags it has.
public enum ID3Tags {
    /// Vorbis comment keys and their ID3v2.4 text frames.
    static let textFrames: [String: String] = [
        "TITLE": "TIT2", "ARTIST": "TPE1", "ALBUMARTIST": "TPE2", "ALBUM": "TALB", "DATE": "TDRC",
        "ORIGINALDATE": "TDOR", "DISCSUBTITLE": "TSST", "ISRC": "TSRC", "LABEL": "TPUB", "GENRE": "TCON",
        "COMPILATION": "TCMP",
    ]

    /// Vorbis comment keys and the descriptions of their TXXX frames, as MusicBrainz Picard writes them.
    static let userFrames: [String: String] = [
        "BARCODE": "BARCODE", "CATALOGNUMBER": "CATALOGNUMBER", "RELEASECOUNTRY": "MusicBrainz Album Release Country",
        "MUSICBRAINZ_ALBUMID": "MusicBrainz Album Id", "MUSICBRAINZ_RELEASEGROUPID": "MusicBrainz Release Group Id",
        "MUSICBRAINZ_ALBUMARTISTID": "MusicBrainz Album Artist Id", "MUSICBRAINZ_ARTISTID": "MusicBrainz Artist Id",
    ]

    /// Space after the frames, for later edits.
    static let paddingBytes = 2048

    public static func write(_ comments: [(key: String, value: String)], cover: EmbeddedCover?, to url: URL) throws {
        var audio = try Data(contentsOf: url)
        // Take away an ID3v2 tag at the start, and an ID3v1 tag at the end.
        if audio.count >= 10, audio.prefix(3) == Data("ID3".utf8) {
            let bytes = [UInt8](audio[audio.startIndex..<(audio.startIndex + 10)])
            let size = bytes[6...9].reduce(0) { $0 << 7 | Int($1 & 0x7F) } + (bytes[5] & 0x10 != 0 ? 20 : 10)
            audio = audio.dropFirst(min(size, audio.count))
        }
        if audio.count >= 128, audio.suffix(128).prefix(3) == Data("TAG".utf8) {
            audio = audio.dropLast(128)
        }
        try (tag(comments, cover: cover) + audio).write(to: url, options: .atomic)
    }

    static func tag(_ comments: [(key: String, value: String)], cover: EmbeddedCover?) -> Data {
        var values = [String: [String]]()
        var order = [String]()
        for (key, value) in comments {
            if values[key] == nil { order.append(key) }
            values[key, default: []].append(value)
        }
        var frames = Data()
        func text(_ id: String, _ list: [String]) {
            frames += frame(id, Data([3]) + Data(list.joined(separator: "\0").utf8))
        }
        for key in order {
            let list = values[key]!
            if let id = textFrames[key] {
                text(id, list)
            } else if let description = userFrames[key] {
                frames += frame(
                    "TXXX", Data([3]) + Data(description.utf8) + Data([0]) + Data(list.joined(separator: "\0").utf8))
            } else if key == "MUSICBRAINZ_TRACKID", let id = list.first {
                // MusicBrainz Picard keeps the recording ID in a UFID frame.
                frames += frame("UFID", Data("http://musicbrainz.org".utf8) + Data([0]) + Data(id.utf8))
            }
        }
        func pair(_ number: String, _ total: String) -> [String]? {
            guard let number = values[number]?.first else { return nil }
            return [values[total]?.first.map { "\(number)/\($0)" } ?? number]
        }
        if let track = pair("TRACKNUMBER", "TRACKTOTAL") { text("TRCK", track) }
        if let disc = pair("DISCNUMBER", "DISCTOTAL") { text("TPOS", disc) }
        text("TSSE", [FLACTags.vendor])
        if let cover, let mime = cover.image.mimeType {
            // Text encoding 0, the MIME type, picture type 3 (front cover), an empty description, the image.
            frames += frame("APIC", Data([0]) + Data(mime.utf8) + Data([0, 3, 0]) + cover.image.data)
        }
        frames += Data(count: paddingBytes)
        return Data("ID3".utf8) + Data([4, 0, 0]) + syncsafe(frames.count) + frames
    }

    static func frame(_ id: String, _ body: Data) -> Data {
        Data(id.utf8) + syncsafe(body.count) + Data([0, 0]) + body
    }

    /// A size in four bytes of 7 bits each, as ID3v2.4 writes sizes.
    static func syncsafe(_ value: Int) -> Data {
        Data((0..<4).reversed().map { UInt8(value >> (7 * $0) & 0x7F) })
    }

    /// The text frames of a file's ID3v2 tag, by frame ID, for tests and checks.
    public static func readTextFrames(_ url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        guard data.count >= 10, data.prefix(3) == Data("ID3".utf8) else { return [:] }
        let bytes = [UInt8](data)
        let end = 10 + bytes[6...9].reduce(0) { $0 << 7 | Int($1 & 0x7F) }
        guard end <= bytes.count else { throw MP3Error.malformedID3Tag(url) }
        var frames = [String: String]()
        var index = 10
        while index + 10 <= end, bytes[index] != 0 {
            let id = String(decoding: bytes[index..<(index + 4)], as: UTF8.self)
            let size = bytes[(index + 4)..<(index + 8)].reduce(0) { $0 << 7 | Int($1 & 0x7F) }
            guard index + 10 + size <= end else { throw MP3Error.malformedID3Tag(url) }
            let body = bytes[(index + 10)..<(index + 10 + size)]
            if id.hasPrefix("T"), let encoding = body.first, encoding == 3 {
                frames[id] = String(decoding: body.dropFirst(), as: UTF8.self)
            }
            index += 10 + size
        }
        return frames
    }
}
