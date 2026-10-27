import Foundation

/// The CD-Text of a disc: titles and names that some discs carry in their lead-in.
///
/// The drive gives CD-Text as 18-byte packs: a type (0x80 titles, 0x81 performers, and so
/// on), a track number, a sequence number, a block and character position, 12 bytes of
/// text, and a CRC-16. Text runs across packs as strings that end in a null; each string
/// is the next track's, starting at the pack's track number (0 is the disc). A TAB (0x09)
/// means "the same as the track before".
///
/// A disc can carry up to 8 blocks, each in its own language and character set: ISO 8859-1,
/// ASCII, or MS-JIS (Shift-JIS, as Microsoft extended it, for Japanese). MS-JIS text has two
/// bytes a character, so two nulls end a string and two TABs repeat one. The fields hold one
/// block: the one in the user's language if the disc has it, else block 0. `otherBlocks`
/// holds the rest.
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
    /// for example "English" for block 0 and "Japanese" for block 1.
    public var languages: [Int: String] = [:]
    /// The character set of the block the text comes from: "ISO 8859-1", "ASCII", or "MS-JIS".
    public var characterSet: String?
    /// The block the text comes from. Nil in older reports, which read block 0 only.
    public var block: Int?
    /// The disc's other blocks, by block number, each with its own text and character set.
    /// Nil if the disc has one block.
    public var otherBlocks: [Int: CDText]?

    /// The genres that CD-Text defines, by code.
    static let genres = [
        2: "Adult Contemporary", 3: "Alternative Rock", 4: "Children's", 5: "Classical", 6: "Contemporary Christian",
        7: "Country", 8: "Dance", 9: "Easy Listening", 10: "Erotic", 11: "Folk", 12: "Gospel", 13: "Hip Hop",
        14: "Jazz", 15: "Latin", 16: "Musical", 17: "New Age", 18: "Opera", 19: "Operetta", 20: "Pop", 21: "Rap",
        22: "Reggae", 23: "Rock", 24: "Rhythm & Blues", 25: "Sound Effects", 26: "Spoken Word", 27: "World Music",
    ]

    /// Some of the language codes of the EBU's list (Tech 3264, appendix 3), which CD-Text
    /// uses, with each language's ISO 639-1 code.
    static let languageNames: [Int: (name: String, code: String)] = [
        0x06: ("Czech", "cs"), 0x07: ("Danish", "da"), 0x08: ("German", "de"), 0x09: ("English", "en"),
        0x0A: ("Spanish", "es"), 0x0F: ("French", "fr"), 0x14: ("Icelandic", "is"), 0x15: ("Italian", "it"),
        0x1B: ("Hungarian", "hu"), 0x1D: ("Dutch", "nl"), 0x1E: ("Norwegian", "no"), 0x20: ("Polish", "pl"),
        0x21: ("Portuguese", "pt"), 0x27: ("Finnish", "fi"), 0x28: ("Swedish", "sv"), 0x29: ("Turkish", "tr"),
        0x46: ("Vietnamese", "vi"), 0x4A: ("Thai", "th"), 0x56: ("Russian", "ru"), 0x65: ("Korean", "ko"),
        0x69: ("Japanese", "ja"), 0x6A: ("Indonesian", "id"), 0x6C: ("Hebrew", "he"), 0x70: ("Greek", "el"),
        0x75: ("Chinese", "zh"), 0x7E: ("Arabic", "ar"),
    ]

    /// The character sets that the size information names, by code.
    static let characterSets = [0x00: "ISO 8859-1", 0x01: "ASCII", 0x80: "MS-JIS"]

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
        self.init(bytes: bytes, preferring: Locale.preferredLanguages)
    }

    /// Reads CD-Text, with the fields from the block in the first of `languages` (such as
    /// "ja-JP") that the disc has, else from block 0.
    public init?(bytes: [UInt8], preferring languages: [String]) {
        let packs = Self.packs(in: bytes).filter { $0[1] & 0x80 == 0 }
        var blocks = [Int: CDText]()
        for number in Set(packs.map(Self.blockNumber)) {
            let block = CDText(packs: packs.filter { Self.blockNumber($0) == number })
            if !block.isEmpty { blocks[number] = block }
        }
        // Each block's size information lists the languages of all of them; the lowest block's wins.
        var blockLanguages = [Int: String]()
        for number in blocks.keys.sorted() {
            blockLanguages.merge(blocks[number]!.languages) { first, _ in first }
        }
        let chosen =
            languages.lazy.compactMap { identifier -> Int? in
                let code = Locale(identifier: identifier).language.languageCode?.identifier
                return blocks.keys.sorted().first { Self.languageCode(blockLanguages[$0]) == code }
            }.first ?? blocks.keys.min()
        guard let chosen else { return nil }
        self = blocks[chosen]!
        self.languages = blockLanguages
        block = chosen
        let others = blocks.filter { $0.key != chosen }.mapValues { block in
            var block = block
            block.languages = [:]
            return block
        }
        otherBlocks = others.isEmpty ? nil : others
    }

    /// The languages of a disc with more than one block, the shown one first: "Japanese; also
    /// English". Nil for a disc with one block.
    public var languagesText: String? {
        guard let otherBlocks, let block else { return nil }
        let name = { (number: Int) in self.languages[number] ?? "block \(number)" }
        return name(block) + "; also " + otherBlocks.keys.sorted().map(name).joined(separator: ", ")
    }

    /// The disc's performer and title ("Artist - Album"), with the languages of a disc that has
    /// several: for the report and the disc's info.
    public var summary: String {
        let disc = [performers[0], titles[0]].compactMap { $0 }.joined(separator: " - ")
        return (disc.isEmpty ? "tracks only" : disc) + (languagesText.map { " (\($0))" } ?? "")
    }

    static func blockNumber(_ pack: [UInt8]) -> Int { Int(pack[3] >> 4) & 0x07 }

    /// The ISO 639-1 code of a language that `languages` names.
    static func languageCode(_ name: String?) -> String? {
        languageNames.values.first { $0.name == name }?.code
    }

    /// Reads the packs of one block.
    private init(packs: [[UInt8]]) {
        // The text of each type, in order of the packs' sequence numbers, and whether any of
        // its packs says that it has two bytes a character.
        var texts = [UInt8: (bytes: [UInt8], doubleByte: Bool)]()
        for pack in packs.sorted(by: { $0[2] < $1[2] }) {
            let type = pack[0]
            if texts[type] == nil { texts[type] = ([], false) }
            texts[type]!.bytes += pack[4..<16]
            if pack[3] & 0x80 != 0 { texts[type]!.doubleByte = true }
        }
        // Size information: the block's character set, then (in its third pack) each block's language.
        let info = texts[0x8F]?.bytes ?? []
        let set = info.first.map(Int.init)
        if let set { characterSet = Self.characterSets[set] ?? String(format: "0x%02X", set) }
        if info.count >= 36 {
            // Bytes 20-27: each block's last sequence number (0 if the block is not there).
            // Bytes 28-35: each block's language. Block 0 is always there.
            for block in 0..<8 where block == 0 || info[20 + block] != 0 {
                let code = Int(info[28 + block])
                languages[block] = Self.languageNames[code]?.name ?? String(format: "code 0x%02X", code)
            }
        }
        for (type, text) in texts {
            switch type {
            case 0x87:
                // Two bytes of genre code, then the disc's own text, in ASCII.
                guard text.bytes.count >= 2 else { continue }
                let code = Int(text.bytes[0]) << 8 | Int(text.bytes[1])
                let own = Self.latin1(Array(text.bytes.dropFirst(2).prefix { $0 != 0 }))
                let name = Self.genres[code]
                genre = [name, own.isEmpty ? nil : own].compactMap { $0 }.joined(separator: ": ")
                if genre?.isEmpty == true { genre = nil }
                continue
            case 0x88, 0x89, 0x8D, 0x8F:
                continue  // TOC information, closed information, and size information: not text for people
            default:
                break
            }
            // Titles and names (0x80-0x85) are in the block's character set; the disc ID and
            // the codes are always ASCII.
            let msJIS = (0x80...0x85).contains(type) && (set == 0x80 || text.doubleByte)
            let values = Self.textValues(
                packs.filter { $0[0] == type }, doubleByte: msJIS || text.doubleByte, msJIS: msJIS)
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
    }

    /// Assemble strings using each pack's track and character position. After a missing pack,
    /// discard the partial string and resume at the next known string boundary.
    private static func textValues(_ packs: [[UInt8]], doubleByte: Bool, msJIS: Bool) -> [Int: String] {
        var values = [Int: String]()
        var track = -1
        var lastSequence: Int?
        var current = [UInt8]()
        var complete = false
        var pendingNull = false
        for pack in packs.sorted(by: { $0[2] < $1[2] }) {
            let sequence = Int(pack[2])
            if lastSequence == sequence { continue }  // Repeated lead-in packs carry the same data.
            let headerTrack = Int(pack[1] & 0x7F)
            if (lastSequence.map({ $0 + 1 != sequence }) ?? true) || headerTrack != track {
                current = []
                pendingNull = false
                track = headerTrack
                complete = pack[3] & 0x0F == 0
            }
            lastSequence = sequence
            for byte in pack[4..<16] {
                if byte == 0 && doubleByte && !pendingNull {
                    pendingNull = true
                    continue
                }
                if byte == 0 {
                    if complete, (0...99).contains(track) {
                        let text = msJIS ? String(bytes: current, encoding: .shiftJIS) ?? "" : latin1(current)
                        let value = text == "\t" || text == "\t\t" ? values[track - 1] ?? "" : text
                        if !value.isEmpty { values[track] = value }
                    }
                    current = []
                    pendingNull = false
                    complete = true
                    track += 1
                } else {
                    if pendingNull {
                        complete = false
                        current = []
                    }
                    pendingNull = false
                    if complete { current.append(byte) }
                }
            }
        }
        return values
    }

    /// The strings in a type's text, each ending in a null, or in two in double-byte text. No
    /// byte of a Shift-JIS character is 0, so any null ends the string.
    static func strings(in bytes: [UInt8], doubleByte: Bool) -> [[UInt8]] {
        var strings = [[UInt8]]()
        var current = [UInt8]()
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0 {
                strings.append(current)
                current = []
                if doubleByte && index + 1 < bytes.count && bytes[index + 1] == 0 { index += 1 }
            } else {
                current.append(bytes[index])
            }
            index += 1
        }
        return strings
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
