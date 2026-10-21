import Foundation

/// The CD-Text of a disc: titles and names that some discs carry in their lead-in.
///
/// The drive gives CD-Text as 18-byte packs: a type (0x80 titles, 0x81 performers, and so
/// on), a track number, a sequence number, a block and character position, 12 bytes of
/// text, and a CRC-16. Text runs across packs as strings that end in a null; each string
/// is the next track's, starting at the pack's track number (0 is the disc). A TAB (0x09)
/// means "the same as the track before". Only block 0 is read, in ISO 8859-1 (or ASCII).
public struct CDText: Codable, Equatable, Sendable {
    /// Text for the disc (index 0) and its tracks (by track number).
    public var titles: [Int: String] = [:]
    public var performers: [Int: String] = [:]
    public var songwriters: [Int: String] = [:]
    public var composers: [Int: String] = [:]
    public var arrangers: [Int: String] = [:]
    public var messages: [Int: String] = [:]
    /// The disc's UPC or EAN (index 0) and the tracks' ISRCs.
    public var codes: [Int: String] = [:]
    /// The disc ID that the label gave, such as a catalog number (pack type 0x86).
    public var discID: String?
    /// The genre, from the standard's list of codes, with the disc's own text if it has any.
    public var genre: String?
    /// The language of each block, by block number, from the size information (0x8F):
    /// for example "English" for block 0. Only block 0's text is read.
    public var languages: [Int: String] = [:]
    /// Block 0's character set: "ISO 8859-1", "ASCII", or "MS-JIS".
    public var characterSet: String?

    /// The genres that CD-Text defines, by code.
    static let genres = [
        2: "Adult Contemporary", 3: "Alternative Rock", 4: "Children's", 5: "Classical", 6: "Contemporary Christian",
        7: "Country", 8: "Dance", 9: "Easy Listening", 10: "Erotic", 11: "Folk", 12: "Gospel", 13: "Hip Hop",
        14: "Jazz", 15: "Latin", 16: "Musical", 17: "New Age", 18: "Opera", 19: "Operetta", 20: "Pop", 21: "Rap",
        22: "Reggae", 23: "Rock", 24: "Rhythm & Blues", 25: "Sound Effects", 26: "Spoken Word", 27: "World Music",
    ]

    /// Some of the language codes of the EBU's list, which CD-Text uses.
    static let languageNames = [
        0x09: "English", 0x08: "German", 0x0F: "French", 0x0A: "Spanish", 0x15: "Italian", 0x1D: "Dutch",
        0x69: "Japanese", 0x75: "Chinese", 0x65: "Korean",
    ]

    public init() {}

    public var isEmpty: Bool {
        [titles, performers, songwriters, composers, arrangers, messages, codes].allSatisfy(\.isEmpty)
            && discID == nil && genre == nil
    }

    /// The valid packs in the bytes that the drive gives, in order: each is 18 bytes.
    public static func packs(in bytes: [UInt8]) -> [[UInt8]] {
        guard bytes.count >= 4 + 18 else { return [] }
        let length = min(Int(bytes[0]) << 8 | Int(bytes[1]), bytes.count - 2)
        return stride(from: 4, to: 2 + length - 17, by: 18).map { Array(bytes[$0..<($0 + 18)]) }.filter(isValid)
    }

    /// Reads CD-Text from the bytes that the drive gives: a 4-byte header, then the packs.
    /// Packs with a bad CRC are left out. Nil if no pack is valid.
    public init?(bytes: [UInt8]) {
        let packs = Self.packs(in: bytes).filter { ($0[3] >> 4) & 0x07 == 0 }
        guard !packs.isEmpty else { return nil }

        // The text of each type, in order of the packs' sequence numbers.
        var texts = [UInt8: (track: Int, bytes: [UInt8])]()
        for pack in packs.sorted(by: { $0[2] < $1[2] }) {
            let type = pack[0]
            if texts[type] == nil { texts[type] = (Int(pack[1] & 0x7F), []) }
            texts[type]!.bytes += pack[4..<16]
        }
        for (type, text) in texts {
            switch type {
            case 0x87:
                // Two bytes of genre code, then the disc's own text.
                guard text.bytes.count >= 2 else { continue }
                let code = Int(text.bytes[0]) << 8 | Int(text.bytes[1])
                let own = Self.latin1(Array(text.bytes.dropFirst(2).prefix { $0 != 0 }))
                let name = Self.genres[code]
                genre = [name, own.isEmpty ? nil : own].compactMap { $0 }.joined(separator: ": ")
                if genre?.isEmpty == true { genre = nil }
                continue
            case 0x8F:
                // Size information: the character set, then (in its third pack) each block's language.
                let info = text.bytes
                if let code = info.first {
                    characterSet =
                        [0x00: "ISO 8859-1", 0x01: "ASCII", 0x80: "MS-JIS"][code] ?? String(format: "0x%02X", code)
                }
                if info.count >= 36 {
                    // Bytes 20-27: each block's last sequence number (0 if the block is not there).
                    // Bytes 28-35: each block's language. Block 0 is always there.
                    for block in 0..<8 where block == 0 || info[20 + block] != 0 {
                        let code = Int(info[28 + block])
                        languages[block] = Self.languageNames[code] ?? String(format: "code 0x%02X", code)
                    }
                }
                continue
            case 0x88, 0x89, 0x8D:
                continue  // TOC information and closed information: not text for people
            default:
                break
            }
            var strings = [String]()
            var current = [UInt8]()
            for byte in text.bytes {
                if byte == 0 {
                    strings.append(Self.latin1(current))
                    current = []
                } else {
                    current.append(byte)
                }
            }
            var values = [Int: String]()
            for (offset, string) in strings.enumerated() {
                let track = text.track + offset
                let value = string == "\t" ? values[track - 1] ?? "" : string
                if !value.isEmpty { values[track] = value }
            }
            switch type {
            case 0x80: titles = values
            case 0x81: performers = values
            case 0x82: songwriters = values
            case 0x83: composers = values
            case 0x84: arrangers = values
            case 0x85: messages = values
            case 0x8E: codes = values
            case 0x86: discID = values[0]
            default: break
            }
        }
        if isEmpty { return nil }
    }

    /// True if the pack's CRC (CRC-16 CCITT of its first 16 bytes, inverted) is right.
    static func isValid(_ pack: [UInt8]) -> Bool {
        crc(pack[0..<16]) == UInt16(pack[16]) << 8 | UInt16(pack[17])
    }

    /// ISO 8859-1 text: each byte is the character of the same code.
    static func latin1(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    /// CRC-16 CCITT (polynomial 0x1021), inverted, as CD-Text packs carry it.
    static func crc(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? crc << 1 ^ 0x1021 : crc << 1 }
        }
        return ~crc
    }
}
