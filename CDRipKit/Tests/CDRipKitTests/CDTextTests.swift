import Testing

@testable import CDRipKit

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
