import Foundation
import Testing

@testable import SilversideKit

struct CDGraphicsTests {
    /// Packs from track 1 of Information Society's *Information Society* (Tommy Boy, 1988),
    /// read in the MATSHITA (2026-11-02): memory preset, a color table, a tile block, and a
    /// tile block XOR, with their parity as the disc has it.
    static let realPacks: [[UInt8]] = [
        [9, 1, 60, 52, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 13, 7, 42, 32],
        [9, 30, 29, 10, 0, 0, 4, 43, 63, 32, 63, 63, 17, 4, 29, 22, 42, 25, 3, 1, 44, 51, 22, 22],
        [9, 6, 53, 58, 0, 7, 1, 48, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 44, 31, 54, 51],
        [9, 38, 22, 57, 0, 1, 4, 48, 0, 0, 0, 0, 0, 0, 0, 4, 2, 0, 0, 0, 25, 38, 19, 31],
    ]

    /// Raw P–W subchannel that holds `packs`, interleaved as on a disc, with empty packs after.
    static func subchannel(_ packs: [[UInt8]]) -> [UInt8] {
        func swapped(_ index: Int) -> Int {
            [1: 18, 18: 1, 2: 5, 5: 2, 3: 23, 23: 3][index] ?? index
        }
        var raw = [[UInt8]](repeating: [UInt8](repeating: 0, count: 24), count: (packs.count + 7 + 3) / 4 * 4)
        for (pack, symbols) in packs.enumerated() {
            for index in 0..<24 {
                let from = swapped(index)
                raw[pack + from % 8][from] = symbols[index]
            }
        }
        return Array(raw.joined())
    }

    @Test func makesTheParityOfARealDisc() {
        for pack in Self.realPacks {
            #expect(CDGraphics.pack(command: pack[0], instruction: pack[1], data: Array(pack[4..<20])) == pack)
            var checked = pack
            #expect(CDGraphics.check(&checked) == .valid)
        }
        var empty = [UInt8](repeating: 0, count: 24)
        #expect(CDGraphics.check(&empty) == .valid)
    }

    /// One or two wrong symbols, anywhere in the pack, are put right.
    @Test func correctsOneOrTwoWrongSymbols() {
        var random = SplitMix64(state: 1)
        for pack in Self.realPacks {
            for position in 0..<24 {
                var damaged = pack
                damaged[position] ^= UInt8.random(in: 1...63, using: &random)
                #expect(CDGraphics.check(&damaged) == .corrected)
                #expect(damaged == pack)
            }
            for _ in 0..<200 {
                let first = Int.random(in: 0..<24, using: &random)
                let second = (first + Int.random(in: 1..<24, using: &random)) % 24
                var damaged = pack
                damaged[first] ^= UInt8.random(in: 1...63, using: &random)
                damaged[second] ^= UInt8.random(in: 1...63, using: &random)
                #expect(CDGraphics.check(&damaged) == .corrected)
                #expect(damaged == pack)
            }
        }
    }

    /// Three wrong symbols are past the parity: almost always found, never taken as valid.
    @Test func findsMoreDamageThanItCanCorrect() {
        var random = SplitMix64(state: 2)
        var uncorrectable = 0
        let tries = 1000
        for _ in 0..<tries {
            let pack = Self.realPacks[Int.random(in: 0..<Self.realPacks.count, using: &random)]
            var positions = Set<Int>()
            while positions.count < 3 { positions.insert(Int.random(in: 0..<24, using: &random)) }
            var damaged = pack
            for position in positions { damaged[position] ^= UInt8.random(in: 1...63, using: &random) }
            let result = CDGraphics.check(&damaged)
            #expect(result != .valid)
            if result == .uncorrectable { uncorrectable += 1 }
        }
        #expect(uncorrectable * 100 >= tries * 95)
    }

    /// Checked packs come out corrected, and a pack past correction comes out as zeros.
    @Test func checksThePacksOfASubchannel() {
        var packs = Array(repeating: Self.realPacks[2], count: 16)
        packs[3][10] ^= 5
        packs[7][1] ^= 1
        packs[7][2] ^= 2
        packs[7][3] ^= 3
        let checked = CDGraphics.checkedPacks(Self.subchannel(packs))
        #expect(checked.corrected == 1)
        #expect(checked.uncorrectable == 1)
        #expect(checked.packs[3] == Self.realPacks[2])
        #expect(checked.packs[7] == [UInt8](repeating: 0, count: 24))
    }

    /// A track's graphics are saved as a .cdg file, 4 packs a sector from its index 01, with
    /// the packs corrected; a track with none gets no file, and a drive with no subchannel throws.
    @Test func savesATracksGraphics() throws {
        let toc = try TOC(audioTrackStarts: [0, 300, 600], leadOutLBA: 900)
        let drive = SimulatedDrive(toc: toc, samples: [UInt32](repeating: 0, count: 900 * CDDA.samplesPerSector))
        var packs = Array(repeating: Self.realPacks[2], count: 600 * 4)
        packs[1250][12] ^= 9
        let pw = Self.subchannel(packs)
        // With the 2 sectors after, which hold the ends of the last packs.
        for sector in 0..<(pw.count / 96) {
            drive.subchannelPW?[sector] = Array(pw[(sector * 96)..<(sector * 96 + 96)])
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let second = folder.appending(path: "Track 02.cdg")
        let graphics = try CDGraphicsReader.read(toc.audioTracks[1], in: toc, drive: drive, to: second)
        #expect(graphics == RipReport.Graphics(file: "Track 02.cdg", correctedPacks: 1))
        let saved = [UInt8](try Data(contentsOf: second))
        #expect(saved == Array(Array(repeating: Self.realPacks[2], count: 1200).joined()))

        // A pack damaged past correction is read again, and left out if every read is damaged.
        drive.flakySubchannel = [310: 1, 320: 9]
        let flaky = try CDGraphicsReader.read(toc.audioTracks[1], in: toc, drive: drive, to: second)
        #expect(
            flaky == RipReport.Graphics(file: "Track 02.cdg", correctedPacks: 1, rereadPacks: 1, uncorrectablePacks: 1))
        let saved2 = [UInt8](try Data(contentsOf: second))
        #expect(Array(saved2[(40 * 24)..<(41 * 24)]) == Self.realPacks[2])
        #expect(saved2[(80 * 24)..<(81 * 24)].allSatisfy { $0 == 0 })

        let third = folder.appending(path: "Track 03.cdg")
        #expect(try CDGraphicsReader.read(toc.audioTracks[2], in: toc, drive: drive, to: third) == nil)
        #expect(!FileManager.default.fileExists(atPath: third.path))
        drive.subchannelPW = nil
        #expect(throws: DriveError.self) {
            try CDGraphicsReader.read(toc.audioTracks[0], in: toc, drive: drive, to: third)
        }
    }
}
