import Foundation
import Testing

@testable import SilversideKit

struct CDTextTests {
    /// Packs of one type, as a disc holds them: 12 bytes of text each, the track of the
    /// string that the pack's first byte belongs to, and a CRC.
    static func packs(type: UInt8, _ strings: [String], sequence: inout UInt8) -> [UInt8] {
        let bytes: [UInt8] = strings.flatMap { Array($0.utf8) + [0] }
        var result = [UInt8]()
        for start in stride(from: 0, to: bytes.count, by: 12) {
            let track = bytes[0..<start].filter { $0 == 0 }.count
            let stringStart = bytes[0..<start].lastIndex(of: 0).map { $0 + 1 } ?? 0
            var pack: [UInt8] = [type, UInt8(track), sequence, UInt8(min(start - stringStart, 15))]
            pack += bytes[start..<min(start + 12, bytes.count)]
            pack += [UInt8](repeating: 0, count: 16 - pack.count)
            let crc = CDText.crc(pack[...])
            result += pack + [UInt8(crc >> 8), UInt8(crc & 0xFF)]
            sequence &+= 1
        }
        return result
    }

    /// Packs of one type in one block: in MS-JIS (Shift-JIS, two nulls after each string, and
    /// the double-byte flag), or else in ISO 8859-1.
    static func packs(
        type: UInt8, _ strings: [String], block: Int, msJIS: Bool, sequence: inout UInt8
    ) -> [UInt8] {
        let encoded = strings.map { Array($0.data(using: msJIS ? .shiftJIS : .isoLatin1)!) }
        let terminator: [UInt8] = msJIS ? [0, 0] : [0]
        // Where each string starts, to give each pack its first string's track.
        var starts = [Int]()
        var bytes = [UInt8]()
        for string in encoded {
            starts.append(bytes.count)
            bytes += string + terminator
        }
        var result = [UInt8]()
        for start in stride(from: 0, to: bytes.count, by: 12) {
            let track = starts.lastIndex { $0 <= start }!
            let flags = UInt8(block << 4) | (msJIS ? 0x80 : 0)
            var pack: [UInt8] = [type, UInt8(track), sequence, flags | UInt8(min(start - starts[track], 15))]
            pack += bytes[start..<min(start + 12, bytes.count)]
            pack += [UInt8](repeating: 0, count: 16 - pack.count)
            let crc = CDText.crc(pack[...])
            result += pack + [UInt8(crc >> 8), UInt8(crc & 0xFF)]
            sequence &+= 1
        }
        return result
    }

    /// A block's size information (three 0x8F packs): its character set, and the last
    /// sequence number and the language of each block.
    static func sizeInformation(
        block: Int, characterSet: UInt8, lastSequences: [UInt8], languages: [UInt8], sequence: inout UInt8
    ) -> [UInt8] {
        var info: [UInt8] = [characterSet, 1, 2, 0] + [UInt8](repeating: 0, count: 16)
        info += (0..<8).map { $0 < lastSequences.count ? lastSequences[$0] : 0 }
        info += (0..<8).map { $0 < languages.count ? languages[$0] : 0 }
        var result = [UInt8]()
        for part in 0..<3 {
            var pack: [UInt8] = [0x8F, UInt8(part), sequence, UInt8(block << 4)] + info[(part * 12)..<(part * 12 + 12)]
            let crc = CDText.crc(pack[...])
            pack += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
            result += pack
            sequence &+= 1
        }
        return result
    }

    /// A disc as the one in the picture: English in block 0, Japanese in block 1, with a TAB
    /// for "the same performer" in each.
    static func twoLanguages() -> [UInt8] {
        // Each block's size information gives the last sequence number of both, so the
        // packs are made twice: first to count them.
        var lastSequences: [UInt8] = [0, 0]
        var packs = [UInt8]()
        for _ in 0..<2 {
            var sequence: UInt8 = 0
            packs = Self.packs(
                type: 0x80, ["Jazz Standards", "Autumn Leaves", "Misty"], block: 0, msJIS: false, sequence: &sequence)
            packs += Self.packs(type: 0x81, ["Akiko", "Akiko", "\t"], block: 0, msJIS: false, sequence: &sequence)
            packs += Self.sizeInformation(
                block: 0, characterSet: 0x00, lastSequences: lastSequences, languages: [0x09, 0x69],
                sequence: &sequence)
            lastSequences[0] = sequence - 1
            packs += Self.packs(
                type: 0x80, ["ジャズ・スタンダード", "枯葉", "ミスティ"], block: 1, msJIS: true, sequence: &sequence)
            packs += Self.packs(type: 0x81, ["秋子", "秋子", "\t\t"], block: 1, msJIS: true, sequence: &sequence)
            packs += Self.sizeInformation(
                block: 1, characterSet: 0x80, lastSequences: lastSequences, languages: [0x09, 0x69],
                sequence: &sequence)
            lastSequences[1] = sequence - 1
        }
        return disc(packs)
    }

    @Test func readsMSJISInTheUsersLanguage() throws {
        let text = try #require(CDText(bytes: Self.twoLanguages(), preferring: ["ja-JP", "en-US"]))
        #expect(text.block == 1 && text.characterSet == "MS-JIS")
        #expect(text.titles == [0: "ジャズ・スタンダード", 1: "枯葉", 2: "ミスティ"])
        // Two TABs are the same as the track before.
        #expect(text.performers == [0: "秋子", 1: "秋子", 2: "秋子"])
        #expect(text.languages == [0: "English", 1: "Japanese"])
        let english = try #require(text.otherBlocks?[0])
        #expect(english.titles[1] == "Autumn Leaves" && english.characterSet == "ISO 8859-1")
        #expect(text.summary == "秋子 - ジャズ・スタンダード (Japanese; also English)")
    }

    @Test func readsBlock0WhenTheDiscLacksTheUsersLanguage() throws {
        let text = try #require(CDText(bytes: Self.twoLanguages(), preferring: ["de-DE"]))
        #expect(text.block == 0 && text.titles[0] == "Jazz Standards")
        #expect(text.performers == [0: "Akiko", 1: "Akiko", 2: "Akiko"])
        #expect(text.otherBlocks?[1]?.titles[2] == "ミスティ")
        let english = try #require(CDText(bytes: Self.twoLanguages(), preferring: ["en-GB", "ja"]))
        #expect(english.block == 0)
    }

    @Test func readsAJapaneseOnlyDisc() throws {
        var sequence: UInt8 = 0
        var packs = Self.packs(type: 0x80, ["①テスト", "髙橋", ""], block: 0, msJIS: true, sequence: &sequence)
        packs += Self.sizeInformation(
            block: 0, characterSet: 0x80, lastSequences: [sequence + 2], languages: [0x69], sequence: &sequence)
        let text = try #require(CDText(bytes: Self.disc(packs), preferring: ["en"]))
        // Microsoft's characters (① and 髙) decode too, and the empty title does not shift the others.
        #expect(text.titles == [0: "①テスト", 1: "髙橋"] && text.block == 0 && text.otherBlocks == nil)
    }

    static func disc(_ packs: [UInt8]) -> [UInt8] {
        [UInt8((packs.count + 2) >> 8), UInt8((packs.count + 2) & 0xFF), 0, 0] + packs
    }

    /// Track titles in the style of *Clarity of Cal*, with vinyl side numbers.
    @Test func readsTitlesAndPerformers() throws {
        var sequence: UInt8 = 0
        var packs = Self.packs(
            type: 0x80, ["Clarity of Cal", "A1 Big Dipper", "A2 Wait for the Moment", "B1 Tee Time"],
            sequence: &sequence)
        packs += Self.packs(type: 0x81, ["Vulfpeck", "Vulfpeck", "\t", "Cory Wong"], sequence: &sequence)
        let text = try #require(CDText(bytes: Self.disc(packs)))
        #expect(
            text.titles == [0: "Clarity of Cal", 1: "A1 Big Dipper", 2: "A2 Wait for the Moment", 3: "B1 Tee Time"])
        // A TAB is the same as the track before.
        #expect(text.performers == [0: "Vulfpeck", 1: "Vulfpeck", 2: "Vulfpeck", 3: "Cory Wong"])
    }

    @Test func leavesOutPacksWithABadCRC() throws {
        var sequence: UInt8 = 0
        var packs = Self.packs(type: 0x80, ["Album", "One"], sequence: &sequence)
        packs += Self.packs(type: 0x81, ["Artist"], sequence: &sequence)
        packs[packs.count - 1] ^= 0xFF
        let text = try #require(CDText(bytes: Self.disc(packs)))
        #expect(text.titles == [0: "Album", 1: "One"] && text.performers.isEmpty)
        #expect(CDText(bytes: [0, 2, 0, 0]) == nil)
    }

    @Test func readsLatin1() throws {
        var sequence: UInt8 = 0
        var bytes = [UInt8](Self.packs(type: 0x80, ["Caf?"], sequence: &sequence))
        // "é" is 0xE9 in ISO 8859-1, in place of the "?".
        bytes[4 + 3] = 0xE9
        let crc = CDText.crc(bytes[0..<16])
        bytes[16] = UInt8(crc >> 8)
        bytes[17] = UInt8(crc & 0xFF)
        #expect(try #require(CDText(bytes: Self.disc(bytes))).titles[0] == "Café")
    }
}
