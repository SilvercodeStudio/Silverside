import Foundation

extension ID3Tags {
    /// Other programs' text frames, by the Vorbis comment key a summary shows them as.
    static let otherTextFrames: [String: String] = [
        "TYER": "DATE", "TORY": "ORIGINALYEAR", "TCOP": "COPYRIGHT", "TENC": "ENCODEDBY", "TSSE": "ENCODER",
        "TBPM": "BPM", "TIT1": "GROUPING", "TIT3": "SUBTITLE", "TPE3": "CONDUCTOR", "TPE4": "REMIXER",
        "TLAN": "LANGUAGE", "TKEY": "KEY", "TSOT": "TITLESORT", "TSOA": "ALBUMSORT", "TSOC": "COMPOSERSORT",
        "TDRL": "RELEASEDATE", "TMOO": "MOOD",
    ]

    /// The tags of a file's ID3v2.3 or ID3v2.4 tag, as Vorbis comment keys (`textFrames`,
    /// `userFrames`, and other programs' frames), in the tag's order; TRCK and TPOS give the
    /// number and the total; TXXX frames that Silverside does not know keep their description as
    /// the key, and other frames their ID. The front cover (APIC type 3, else the first picture).
    /// Nil if the file has no ID3v2 tag that this reads (none, or ID3v2.2, ...).
    public static func read(_ url: URL) throws -> (comments: [(key: String, value: String)], cover: Data?)? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 10), header.count == 10, header.prefix(3) == Data("ID3".utf8)
        else { return nil }
        let bytes = [UInt8](header)
        let version = bytes[3]
        guard version == 3 || version == 4 else { return nil }
        let size = bytes[6...9].reduce(0) { $0 << 7 | Int($1 & 0x7F) }
        guard let body = try handle.read(upToCount: size), body.count == size else {
            throw MP3Error.malformedID3Tag(url)
        }
        var tag = [UInt8](body)
        let flags = bytes[5]
        // ID3v2.3 undoes the whole tag's unsynchronisation; ID3v2.4 does it frame by frame.
        if flags & 0x80 != 0, version == 3 { tag = resynchronized(tag) }
        var index = 0
        if flags & 0x40 != 0, tag.count >= 4 {
            let extended = tag[0..<4].reduce(0) { $0 << (version == 4 ? 7 : 8) | Int($1) }
            index = version == 4 ? extended : extended + 4
        }
        let textKeys = Dictionary(uniqueKeysWithValues: textFrames.map { ($0.value, $0.key) })
        let userKeys = Dictionary(uniqueKeysWithValues: userFrames.map { ($0.value, $0.key) })
        var comments = [(key: String, value: String)]()
        var cover: Data?
        var firstPicture: Data?
        while index + 10 <= tag.count, tag[index] != 0 {
            let id = String(decoding: tag[index..<(index + 4)], as: UTF8.self)
            let sizeBytes = tag[(index + 4)..<(index + 8)]
            let frameSize = sizeBytes.reduce(0) { $0 << (version == 4 ? 7 : 8) | Int($1) }
            let format = tag[index + 9]
            guard index + 10 + frameSize <= tag.count else { break }
            var frame = Array(tag[(index + 10)..<(index + 10 + frameSize)])
            index += 10 + frameSize
            // Compressed or encrypted frames are left out.
            let compressedOrEncrypted: UInt8 = version == 4 ? 0x0C : 0xC0
            if format & compressedOrEncrypted != 0 { continue }
            if version == 4 {
                if format & 0x02 != 0 { frame = resynchronized(frame) }
                if format & 0x01 != 0 { frame = Array(frame.dropFirst(4)) }
            }
            guard let encoding = frame.first else { continue }
            switch id {
            case "TXXX":
                let parts = texts(Array(frame.dropFirst()), encoding: encoding)
                guard let description = parts.first else { continue }
                let key = userKeys[description] ?? description.uppercased()
                comments += parts.dropFirst().map { (key, $0) }
            case "COMM", "USLT":
                // The language, then a description and the text.
                guard frame.count > 4 else { continue }
                let parts = texts(Array(frame.dropFirst(4)), encoding: encoding)
                if let text = parts.dropFirst().first, !text.isEmpty {
                    comments.append((id == "COMM" ? "COMMENT" : "LYRICS", text))
                }
            case "UFID":
                let parts = frame.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2, String(decoding: parts[0], as: UTF8.self) == "http://musicbrainz.org" {
                    comments.append(("MUSICBRAINZ_TRACKID", String(decoding: parts[1], as: UTF8.self)))
                }
            case "APIC":
                guard let picture = picture(frame) else { continue }
                if firstPicture == nil { firstPicture = picture.data }
                if picture.type == 3, cover == nil { cover = picture.data }
            case "TRCK", "TPOS":
                guard let value = texts(Array(frame.dropFirst()), encoding: encoding).first else { continue }
                let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
                let (key, totalKey) = id == "TRCK" ? ("TRACKNUMBER", "TRACKTOTAL") : ("DISCNUMBER", "DISCTOTAL")
                if let number = parts.first { comments.append((key, number)) }
                if parts.count == 2 { comments.append((totalKey, parts[1])) }
            default:
                guard id.hasPrefix("T") else { continue }
                let key = textKeys[id] ?? otherTextFrames[id] ?? id
                // ID3v2.3 keeps the year in TYER; a TDRC's date comes first where both are.
                if id == "TYER", comments.contains(where: { $0.key == "DATE" }) { continue }
                comments += texts(Array(frame.dropFirst()), encoding: encoding).filter { !$0.isEmpty }.map { (key, $0) }
            }
        }
        return (comments, cover ?? firstPicture)
    }

    /// The strings of a frame's text, split at each terminator: ISO-8859-1 (0), UTF-16 with a
    /// byte order mark (1), UTF-16 big-endian (2), or UTF-8 (3).
    static func texts(_ bytes: [UInt8], encoding: UInt8) -> [String] {
        var strings = [String]()
        if encoding == 1 || encoding == 2 {
            var current = [UInt8]()
            var bigEndian = encoding == 2
            var index = 0
            func finish() {
                var units = [UInt16]()
                var start = 0
                if current.count >= 2, current[0] == 0xFF, current[1] == 0xFE {
                    bigEndian = false
                    start = 2
                } else if current.count >= 2, current[0] == 0xFE, current[1] == 0xFF {
                    bigEndian = true
                    start = 2
                }
                var at = start
                while at + 1 < current.count {
                    units.append(
                        bigEndian
                            ? UInt16(current[at]) << 8 | UInt16(current[at + 1])
                            : UInt16(current[at + 1]) << 8 | UInt16(current[at]))
                    at += 2
                }
                strings.append(String(decoding: units, as: UTF16.self))
                current = []
            }
            while index + 1 < bytes.count {
                if bytes[index] == 0, bytes[index + 1] == 0 {
                    finish()
                } else {
                    current += [bytes[index], bytes[index + 1]]
                }
                index += 2
            }
            if !current.isEmpty { finish() }
        } else {
            for part in bytes.split(separator: 0, omittingEmptySubsequences: false) {
                strings.append(
                    encoding == 3
                        ? String(decoding: part, as: UTF8.self)
                        : String(part.map { Character(Unicode.Scalar($0)) }))
            }
        }
        // A trailing terminator gives an empty last string.
        if strings.count > 1, strings.last == "" { strings.removeLast() }
        return strings
    }

    /// An APIC frame's picture type and image.
    static func picture(_ frame: [UInt8]) -> (type: UInt8, data: Data)? {
        guard let encoding = frame.first, let mimeEnd = frame.dropFirst().firstIndex(of: 0), mimeEnd + 1 < frame.count
        else { return nil }
        let type = frame[mimeEnd + 1]
        var at = mimeEnd + 2
        // The description ends with one zero byte, or two in UTF-16.
        if encoding == 1 || encoding == 2 {
            while at + 1 < frame.count, !(frame[at] == 0 && frame[at + 1] == 0) { at += 2 }
            at += 2
        } else {
            while at < frame.count, frame[at] != 0 { at += 1 }
            at += 1
        }
        guard at < frame.count else { return nil }
        return (type, Data(frame[at...]))
    }

    /// Bytes with ID3's unsynchronisation undone: each 0xFF 0x00 becomes 0xFF.
    static func resynchronized(_ bytes: [UInt8]) -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            result.append(bytes[index])
            if bytes[index] == 0xFF, index + 1 < bytes.count, bytes[index + 1] == 0 { index += 1 }
            index += 1
        }
        return result
    }
}
