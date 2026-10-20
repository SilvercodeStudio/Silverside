import Foundation
import Testing

@testable import CDRipKit

struct GaloisField16Tests {
    typealias GF = GaloisField16

    @Test func alphaToThe16IsThePolynomialRemainder() {
        // x^16 = x^12 + x^3 + x + 1 in this field.
        #expect(GF.alphaPower(16) == 0x100B)
        #expect(GF.alphaPower(GF.order) == 1)
    }

    @Test func multiplicationAndDivisionAreInverse() {
        var generator = SplitMix64(state: 7)
        for _ in 0..<1000 {
            let a = UInt16.random(in: 1 ... .max, using: &generator)
            let b = UInt16.random(in: 1 ... .max, using: &generator)
            #expect(GF.divide(GF.multiply(a, b), b) == a)
        }
        #expect(GF.multiply(0, 1234) == 0 && GF.multiply(1, 1234) == 1234)
    }
}

struct ReedSolomonDecoderTests {
    typealias GF = GaloisField16

    /// The syndromes of errors at the given degrees: S_i = Σ e × α^(i × degree).
    func syndromes(of errors: [Int: UInt16], count: Int) -> [UInt16] {
        (0..<count).map { i in
            errors.reduce(0) { $0 ^ GF.multiply($1.value, GF.alphaPower(i * $1.key)) }
        }
    }

    @Test(arguments: 1...4)
    func correctsUpToHalfTheSyndromeCount(errorCount: Int) {
        var generator = SplitMix64(state: UInt64(errorCount))
        var errors = [Int: UInt16]()
        while errors.count < errorCount {
            errors[Int.random(in: 0..<30_000, using: &generator)] = UInt16.random(in: 1 ... .max, using: &generator)
        }
        let corrections = ReedSolomonDecoder.corrections(syndromes: syndromes(of: errors, count: 8), length: 30_000)
        #expect(corrections.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.degree, $0.error) }) } == errors)
    }

    /// e erasures and v other errors can be corrected while e + 2v ≤ 8.
    @Test(arguments: [(8, 0), (6, 1), (4, 2), (2, 3)])
    func correctsErasuresAndErrors(erasureCount: Int, errorCount: Int) {
        var generator = SplitMix64(state: UInt64(10 * erasureCount + errorCount))
        var errors = [Int: UInt16]()
        while errors.count < erasureCount + errorCount {
            errors[Int.random(in: 0..<30_000, using: &generator)] = UInt16.random(in: 1 ... .max, using: &generator)
        }
        let erasures = Array(errors.keys.sorted().prefix(erasureCount))
        let corrections = ReedSolomonDecoder.corrections(
            syndromes: syndromes(of: errors, count: 8), length: 30_000, erasures: erasures)
        #expect(corrections.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.degree, $0.error) }) } == errors)
    }

    /// A suspect symbol that is right gets no correction.
    @Test func ignoresAnErasureWithNoError() {
        let errors: [Int: UInt16] = [100: 7, 2000: 9]
        let corrections = ReedSolomonDecoder.corrections(
            syndromes: syndromes(of: errors, count: 8), length: 3000, erasures: [100, 555])
        #expect(corrections.map { Set($0.map(\.degree)) } == [100, 2000])
    }

    @Test func reportsNoErrorsForZeroSyndromes() {
        #expect(ReedSolomonDecoder.corrections(syndromes: [0, 0, 0, 0], length: 100) == [])
    }

    @Test func refusesTooManyErrors() {
        let errors: [Int: UInt16] = [3: 1, 70: 2, 900: 3, 1500: 4, 2000: 5]
        #expect(ReedSolomonDecoder.corrections(syndromes: syndromes(of: errors, count: 8), length: 3000) == nil)
    }
}

struct CTDBTests {
    /// A disc of 6 rows and some remainder, with random audio.
    func disc(seed: UInt64 = 3) -> (layout: CTDBLayout, audio: [UInt32]) {
        let layout = CTDBLayout(sampleCount: 6 * CTDBLayout.strideSamples + 500)
        var generator = SplitMix64(state: seed)
        return (layout, (0..<layout.sampleCount).map { _ in UInt32.random(in: .min ... .max, using: &generator) })
    }

    @Test func layoutLeavesOutTheFirstAndLastRows() {
        let layout = CTDBLayout(sampleCount: 6 * CTDBLayout.strideSamples + 500)
        #expect(layout.rows == 4)
        #expect(layout.prefixSamples == 5880 && layout.suffixSamples == 6380)
        #expect(
            layout.prefixSamples + layout.rows * CTDBLayout.strideSamples + layout.suffixSamples == layout.sampleCount)
    }

    @Test func crcIsTheZlibChecksum() {
        // "12345678" as two little-endian samples.
        #expect(CRC32.checksum(of: [0x3433_3231, 0x3837_3635]) == 0x9AE0_DAAF)
    }

    /// Each column's syndromes are its words, first row at the highest degree, at α^i.
    @Test func syndromesFollowTheDefinition() {
        let (layout, audio) = disc()
        let shift = 37
        let syndromes = CTDB.syndromes(of: audio, layout: layout, shift: shift, count: 8)
        for column in [0, 1, 2, 5001, CTDBLayout.stride - 1] {
            for i in 0..<8 {
                var expected: UInt16 = 0
                for row in 0..<layout.rows {
                    let sample = audio[layout.prefixSamples + shift + row * CTDBLayout.strideSamples + column / 2]
                    let word = UInt16(truncatingIfNeeded: sample >> (16 * (column % 2)))
                    expected ^= GaloisField16.multiply(word, GaloisField16.alphaPower(i * (layout.rows - 1 - row)))
                }
                #expect(syndromes[column * 8 + i] == expected)
            }
        }
    }

    @Test func readsRepairDataByColumn() {
        // Syndrome 0 of every column, then syndrome 1 of every column.
        var bytes = [UInt8](repeating: 0, count: 2 * 2 * CTDBLayout.stride)
        bytes[2 * 5] = 0x34
        bytes[2 * 5 + 1] = 0x12
        bytes[2 * (CTDBLayout.stride + 5)] = 0x78
        let syndromes = CTDB.syndromes(fromRepairData: bytes, count: 2)
        #expect(syndromes?[5 * 2] == 0x1234 && syndromes?[5 * 2 + 1] == 0x0078)
        #expect(CTDB.syndromes(fromRepairData: [1, 2, 3], count: 2) == nil)
    }

    @Test func repairsErrorsThatTheSyndromesCanCorrect() {
        let (layout, original) = disc()
        let shift = -120
        let reference = CTDB.syndromes(of: original, layout: layout, shift: shift, count: 8)
        let crc = CTDB.discCRC(of: original, layout: layout, shift: shift)
        var damaged = original
        // Two whole sectors in one row, and three samples in other rows: at most 2 errors in a column.
        let changed = Array(20_000..<(20_000 + 2 * 588)) + [6_000, 9_000, 25_000]
        for sample in changed { damaged[sample] ^= 0x0101_0001 }
        #expect(CTDB.discCRC(of: damaged, layout: layout, shift: shift) != crc)

        let result = CTDB.repair(&damaged, layout: layout, shift: shift, reference: reference, count: 8, crc: crc)
        #expect(result == .repaired(changedSamples: changed.sorted()))
        #expect(damaged == original)
        #expect(
            CTDB.repair(&damaged, layout: layout, shift: shift, reference: reference, count: 8, crc: crc) == .noErrors)
    }

    /// Four errors in one column, with only 2 syndromes: the decoder may take them for
    /// one error elsewhere. The CRC check catches that, and the audio stays as it was.
    @Test func leavesTheAudioUnchangedWhenTheRepairCannotBeRight() {
        let (layout, original) = disc()
        let reference = CTDB.syndromes(of: original, layout: layout, shift: 0, count: 2)
        let crc = CTDB.discCRC(of: original, layout: layout)
        var damaged = original
        for row in 0..<4 { damaged[layout.prefixSamples + row * CTDBLayout.strideSamples] ^= 0x0000_0001 }
        let before = damaged
        let result = CTDB.repair(&damaged, layout: layout, shift: 0, reference: reference, count: 2, crc: crc)
        #expect(
            result == .uncorrectable(columns: [0], columnsWithErrors: 1, checked: CTDBLayout.stride)
                || { if case .failedCheck(1, _) = result { true } else { false } }())
        #expect(damaged == before)
    }

    /// Errors in the same column of all 4 rows: too many for 6 syndromes as unknown
    /// errors (3 at most), but not as erasures (4, with 2 syndromes spare), when the
    /// ripper knows the sectors.
    @Test func repairsMoreErrorsWhenTheirSectorsAreKnown() {
        let (layout, original) = disc()
        let reference = CTDB.syndromes(of: original, layout: layout, shift: 0, count: 6)
        let crc = CTDB.discCRC(of: original, layout: layout)
        var damaged = original
        let sectors = (0..<4).map { row in
            let start = layout.prefixSamples + row * CTDBLayout.strideSamples + 1000
            return start..<(start + 588)
        }
        for sector in sectors { for sample in sector { damaged[sample] ^= 0x0042_0042 } }
        var withoutSuspects = damaged
        let blind = CTDB.repair(&withoutSuspects, layout: layout, shift: 0, reference: reference, count: 6, crc: crc)
        #expect(blind != .noErrors && withoutSuspects == damaged)
        let result = CTDB.repair(
            &damaged, layout: layout, shift: 0, reference: reference, count: 6, crc: crc, suspects: sectors)
        #expect(result == .repaired(changedSamples: sectors.flatMap { Array($0) }))
        #expect(damaged == original)
    }

    /// Four wrong words in one column, with 2 syndromes: they can fix 1 unknown error or
    /// 2 erasures. Other reads gave the true values of 3 words, which leaves 1 to decode.
    @Test func repairsAColumnWithOtherReadsVersions() {
        let (layout, original) = disc()
        let reference = CTDB.syndromes(of: original, layout: layout, shift: 0, count: 2)
        let crc = CTDB.discCRC(of: original, layout: layout)
        var damaged = original
        let samples = (0..<4).map { layout.prefixSamples + $0 * CTDBLayout.strideSamples + 77 }
        for sample in samples { damaged[sample] ^= 0x0000_0101 }
        let suspects = samples.map { $0..<($0 + 1) }
        var alternatives = [Int: [UInt32]]()
        for sample in samples.prefix(3) { alternatives[sample] = [original[sample]] }

        var alone = damaged
        let blind = CTDB.repair(
            &alone, layout: layout, shift: 0, reference: reference, count: 2, crc: crc, suspects: suspects)
        #expect(blind != .repaired(changedSamples: samples) && alone == damaged)
        let result = CTDB.repair(
            &damaged, layout: layout, shift: 0, reference: reference, count: 2, crc: crc, suspects: suspects,
            alternatives: alternatives)
        #expect(result == .repaired(changedSamples: samples))
        #expect(damaged == original)
    }

    /// Ten wrong words among 20 suspects in one column, with 16 syndromes: too many for
    /// errors at unknown places (8), and too many suspects to erase them all (14, with 2
    /// spare). A subset of 14 suspects that holds the 10 wrong words decodes.
    @Test func repairsAColumnWithTooManySuspectsBySubsets() {
        let layout = CTDBLayout(sampleCount: 30 * CTDBLayout.strideSamples + 500)
        var generator = SplitMix64(state: 5)
        let original = (0..<layout.sampleCount).map { _ in UInt32.random(in: .min ... .max, using: &generator) }
        let reference = CTDB.syndromes(of: original, layout: layout, shift: 0, count: 16)
        let crc = CTDB.discCRC(of: original, layout: layout)
        let samples = (0..<20).map { layout.prefixSamples + $0 * CTDBLayout.strideSamples + 77 }
        var damaged = original
        for sample in samples.prefix(10) { damaged[sample] ^= 0x0000_0101 }
        let result = CTDB.repair(
            &damaged, layout: layout, shift: 0, reference: reference, count: 16, crc: crc,
            suspects: samples.map { $0..<($0 + 1) })
        #expect(result == .repaired(changedSamples: Array(samples.prefix(10))))
        #expect(damaged == original)
    }

    @Test func solvesErasureValues() {
        let degrees = [3, 40, 41]
        let errors: [UInt16] = [0x1234, 0, 0xBEEF]
        let syndromes = (0..<6).map { i in
            zip(degrees, errors).reduce(UInt16(0)) {
                $0 ^ GaloisField16.multiply($1.1, GaloisField16.alphaPower(i * $1.0))
            }
        }
        #expect(CTDB.erasureValues(syndromes, degrees: degrees) == errors)
        var wrong = syndromes
        wrong[5] ^= 1
        #expect(CTDB.erasureValues(wrong, degrees: degrees) == nil)
    }

    @Test(arguments: [0, 1195, -700, 5879])
    func findsTheShiftOfAnEntry(shift: Int) {
        let (layout, audio) = disc()
        let column0 = Array(CTDB.syndromes(of: audio, layout: layout, shift: shift, count: 8)[0..<8])
        let candidates = CTDB.column0Syndromes(of: audio, layout: layout, count: 16)
        #expect(CTDB.shifts(matching: column0, in: candidates, layout: layout).first == .init(shift: shift, errors: 0))
    }
}
