import Foundation

/// How CUETools DB sees a disc's audio, for its checksums and its repair data.
///
/// The audio from the first audio track to the lead-out is a sequence of 16-bit
/// words: left, right, left, and so on. Without its first row, and its last row
/// and the remainder, the sequence is a matrix of rows of `stride` words. Each
/// column is a Reed–Solomon codeword over GF(2^16): its syndrome S_i is the
/// column's polynomial at α^i, with the first row at the highest degree.
///
/// Positions are sample indexes in the disc's audio, where index 0 is the start of
/// the first audio track. A shift `s` reads CTDB position j from audio index j + s.
public struct CTDBLayout: Equatable, Sendable {
    public static let strideSamples = 5880
    /// Words in each row, two for each sample.
    public static let stride = 2 * strideSamples

    /// The samples from the first audio track to the audio lead-out.
    public let sampleCount: Int

    public init(sampleCount: Int) {
        precondition(sampleCount >= 3 * Self.strideSamples, "Too short for CTDB")
        self.sampleCount = sampleCount
    }

    public init(toc: TOC) {
        let first = toc.audioTracks.first?.startLBA ?? 0
        self.init(sampleCount: (toc.audioLeadOutLBA - first) * CDDA.samplesPerSector)
    }

    /// Samples left out at the start: the first row.
    public var prefixSamples: Int { Self.strideSamples }

    /// Samples left out at the end: the last row and the remainder.
    public var suffixSamples: Int { Self.strideSamples + sampleCount % Self.strideSamples }

    public var rows: Int { 2 * sampleCount / Self.stride - 2 }

    /// The shifts that keep the checked part of the audio inside the disc.
    public var shifts: ClosedRange<Int> { -prefixSamples...suffixSamples }
}

/// CRC-32 (the zlib and CUETools DB checksum) of samples as little-endian bytes.
public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { byte in
        (0..<8).reduce(UInt32(byte)) { crc, _ in crc & 1 != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    public static func checksum(of samples: ArraySlice<UInt32>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        table.withUnsafeBufferPointer { table in
            for sample in samples {
                for byte in 0..<4 {
                    crc = table[Int((crc ^ (sample >> (8 * byte))) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        return ~crc
    }
}

/// Checks and repairs a disc's audio with CUETools DB data.
public enum CTDB {
    /// The disc's CRC at `shift`: the samples between the left-out first and last rows.
    public static func discCRC(of audio: [UInt32], layout: CTDBLayout, shift: Int = 0) -> UInt32 {
        precondition(audio.count == layout.sampleCount && layout.shifts.contains(shift))
        return CRC32.checksum(of: audio[(layout.prefixSamples + shift)..<(audio.count - layout.suffixSamples + shift)])
    }

    /// The CRC of each audio track at `shift`. The first track leaves out the first
    /// row, and the last track the last row and the remainder, as for the disc CRC.
    public static func trackCRCs(of audio: [UInt32], toc: TOC, layout: CTDBLayout, shift: Int = 0) -> [UInt32] {
        let audioTracks = toc.audioTracks
        let first = audioTracks[0].startLBA
        return audioTracks.indices.map { index in
            let sectors = toc.sectorRange(of: audioTracks[index])
            var start = (sectors.lowerBound - first) * CDDA.samplesPerSector + shift
            var end = (sectors.upperBound - first) * CDDA.samplesPerSector + shift
            if index == 0 { start += layout.prefixSamples }
            if index == audioTracks.count - 1 { end -= layout.suffixSamples }
            return CRC32.checksum(of: audio[max(start, 0)..<min(end, audio.count)])
        }
    }

    /// The syndromes of every column at `shift`, `count` for each: element
    /// `column × count + i` is S_i of that column. `shift` must be in `layout.shifts`.
    public static func syndromes(of audio: [UInt32], layout: CTDBLayout, shift: Int, count: Int) -> [UInt16] {
        precondition(audio.count == layout.sampleCount && layout.shifts.contains(shift))
        // Multiplying by α^i is linear over GF(2), so a value's product is the XOR of the
        // products of its low and high bytes: two lookups in 512 entries for each i.
        let tables: [UInt16] = (0..<count).flatMap { i in
            (0..<256).map { GaloisField16.multiply(UInt16($0), byAlphaPower: i) }
                + (0..<256).map { GaloisField16.multiply(UInt16($0) << 8, byAlphaPower: i) }
        }
        var syndromes = [UInt16](repeating: 0, count: CTDBLayout.stride * count)
        let rows = layout.rows
        let start = layout.prefixSamples + shift
        // Each part of the columns is independent, so the parts run in parallel. Each part
        // reads its samples of every row in order.
        let parts = 16
        let samplesPerPart = (CTDBLayout.strideSamples + parts - 1) / parts
        audio.withUnsafeBufferPointer { audio in
            tables.withUnsafeBufferPointer { tables in
                syndromes.withUnsafeMutableBufferPointer { syndromes in
                    // The buffers outlive the parallel loop, and each part writes only its own columns.
                    let audioAddress = UInt(bitPattern: audio.baseAddress)
                    let tablesAddress = UInt(bitPattern: tables.baseAddress)
                    let syndromesAddress = UInt(bitPattern: syndromes.baseAddress)
                    DispatchQueue.concurrentPerform(iterations: parts) { part in
                        let audio = UnsafePointer<UInt32>(bitPattern: audioAddress)!
                        let tables = UnsafePointer<UInt16>(bitPattern: tablesAddress)!
                        let syndromes = UnsafeMutablePointer<UInt16>(bitPattern: syndromesAddress)!
                        let first = part * samplesPerPart
                        let end = min(first + samplesPerPart, CTDBLayout.strideSamples)
                        guard first < end else { return }
                        // Horner's rule: each row multiplies a column's S_i by α^i and adds the row's word.
                        for row in 0..<rows {
                            let base = start + row * CTDBLayout.strideSamples
                            for sample in first..<end {
                                let value = audio[base + sample]
                                for half in 0..<2 {
                                    let word = UInt16(truncatingIfNeeded: value >> (16 * half))
                                    let column = syndromes + (2 * sample + half) * count
                                    column[0] ^= word
                                    for i in 1..<count {
                                        let s = column[i]
                                        let table = tables + 512 * i
                                        column[i] = table[Int(s & 0xFF)] ^ table[256 + Int(s >> 8)] ^ word
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return syndromes
    }

    /// Reads CTDB repair data: for each syndrome index i, one little-endian value
    /// for each column. Returns them as `syndromes(of:layout:shift:count:)` does.
    public static func syndromes(fromRepairData bytes: [UInt8], count: Int) -> [UInt16]? {
        let stride = CTDBLayout.stride
        guard bytes.count >= 2 * stride * count else { return nil }
        var syndromes = [UInt16](repeating: 0, count: stride * count)
        for i in 0..<count {
            for column in 0..<stride {
                let at = 2 * (i * stride + column)
                syndromes[column * count + i] = UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
            }
        }
        return syndromes
    }

    /// A shift at which column 0 of the audio agrees with a CTDB entry, and the
    /// number of words in column 0 that differ (0 if it agrees exactly).
    public struct ShiftMatch: Equatable, Sendable {
        public var shift: Int
        public var errors: Int

        public init(shift: Int, errors: Int) {
            self.shift = shift
            self.errors = errors
        }
    }

    /// The column-0 syndromes of the audio at every shift in -strideSamples < s < strideSamples,
    /// `count` for each. Column 0 at shift s ≥ 0 is column 2s at shift 0. At s < 0, it is
    /// column stride + 2s of a pass that starts one row earlier.
    public static func column0Syndromes(of audio: [UInt32], layout: CTDBLayout, count: Int) -> [Int: [UInt16]] {
        let atZero = syndromes(of: audio, layout: layout, shift: 0, count: count)
        let rowEarlier = syndromes(of: audio, layout: layout, shift: -CTDBLayout.strideSamples, count: count)
        var result = [Int: [UInt16]]()
        for shift in (1 - CTDBLayout.strideSamples)..<CTDBLayout.strideSamples {
            let column = shift >= 0 ? 2 * shift : CTDBLayout.stride + 2 * shift
            let source = shift >= 0 ? atZero : rowEarlier
            result[shift] = Array(source[(column * count)..<((column + 1) * count)])
        }
        return result
    }

    /// The shifts at which column 0 agrees with `column0`, the syndromes in a CTDB
    /// lookup, or differs by errors that they can correct; fewest errors first.
    /// `candidates` comes from `column0Syndromes(of:layout:count:)`, with at least as many syndromes.
    /// If no shift has few errors, `fullSearch` looks for up to half as many errors as
    /// syndromes, which is much slower.
    public static func shifts(
        matching column0: [UInt16], in candidates: [Int: [UInt16]], layout: CTDBLayout, fullSearch: Bool = true
    ) -> [ShiftMatch] {
        // At a wrong shift, the difference looks random, and its locator has the full degree.
        // So look for few errors first, which skips the costly search at almost every shift.
        let differences = candidates.mapValues { syndromes in column0.indices.map { syndromes[$0] ^ column0[$0] } }
        let limits = [max(1, column0.count / 2 - 2)] + (fullSearch ? [column0.count / 2] : [])
        for limit in limits {
            var matches = [ShiftMatch]()
            for (shift, difference) in differences {
                if difference.allSatisfy({ $0 == 0 }) {
                    matches.append(ShiftMatch(shift: shift, errors: 0))
                } else if let corrections = ReedSolomonDecoder.corrections(
                    syndromes: difference, length: layout.rows, maximumErrors: limit)
                {
                    matches.append(ShiftMatch(shift: shift, errors: corrections.count))
                }
            }
            if !matches.isEmpty { return matches.sorted { ($0.errors, abs($0.shift)) < ($1.errors, abs($1.shift)) } }
        }
        return []
    }

    public enum RepairResult: Equatable, Sendable {
        /// The audio agrees with the repair data.
        case noErrors
        /// The audio was corrected. Each element is a sample index whose data changed.
        case repaired(changedSamples: [Int])
        /// Some columns have more errors than the repair data can correct. The audio is
        /// not changed. `checked` is the number of columns examined: the repair stops early
        /// when most columns cannot be corrected, as at a wrong shift. `changes` are the
        /// corrections of the other columns, which can still be checked track by track.
        case uncorrectable(columns: [Int], columnsWithErrors: Int, checked: Int, changes: [Change] = [])
        /// The corrections did not give the entry's CRC: there were more errors than the
        /// repair data could detect, so some corrections were wrong. The audio is not
        /// changed. `changes` are the corrections, which can still be checked track by track.
        case failedCheck(columnsWithErrors: Int, changes: [Change])
    }

    /// One correction: XOR `mask` into the sample at index `sample`.
    public struct Change: Equatable, Sendable {
        public var sample: Int
        public var mask: UInt32
    }

    /// Corrects the audio at `shift` with the syndromes from a CTDB entry's repair
    /// data, then checks the result against the entry's CRC. Reed–Solomon cannot always
    /// tell that a column has too many errors, so without the check a repair could be wrong.
    ///
    /// `suspects` are ranges of sample indexes that may be wrong, such as samples that
    /// read differently on different reads. A column that cannot be decoded without
    /// them is decoded again with its suspect words as erasures, which cost the decoder
    /// half as much as errors at unknown places.
    public static func repair(
        _ audio: inout [UInt32], layout: CTDBLayout, shift: Int, reference: [UInt16], count: Int, crc: UInt32,
        suspects: [Range<Int>] = [], alternatives: [Int: [UInt32]] = [:]
    ) -> RepairResult {
        let ours = syndromes(of: audio, layout: layout, shift: shift, count: count)
        let erasures = erasureDegrees(for: suspects, layout: layout, shift: shift)
        let first = layout.prefixSamples + shift
        var changes = [Change]()
        var columnsWithErrors = 0
        var uncorrectable = [Int]()
        func record(_ corrections: [ReedSolomonDecoder.Correction], column: Int) {
            for correction in corrections {
                let row = layout.rows - 1 - correction.degree
                let sample = first + row * CTDBLayout.strideSamples + column / 2
                changes.append(Change(sample: sample, mask: UInt32(correction.error) << (16 * (column % 2))))
            }
        }
        func difference(_ column: Int) -> [UInt16] {
            (0..<count).map { ours[column * count + $0] ^ reference[column * count + $0] }
        }
        for column in 0..<CTDBLayout.stride {
            let difference = difference(column)
            guard difference.contains(where: { $0 != 0 }) else { continue }
            columnsWithErrors += 1
            guard let corrections = decode(difference, length: layout.rows, suspects: erasures[column], count: count)
            else {
                uncorrectable.append(column)
                if columnsWithErrors >= 200 && 2 * uncorrectable.count > columnsWithErrors {
                    return .uncorrectable(
                        columns: uncorrectable, columnsWithErrors: columnsWithErrors, checked: column + 1)
                }
                continue
            }
            record(corrections, column: column)
        }
        // Trying other versions costs many decodes for each column, so it is only worth it
        // when few columns are left, as on a disc that is nearly repaired.
        if !uncorrectable.isEmpty && uncorrectable.count <= maximumColumnsForAlternatives {
            uncorrectable = uncorrectable.filter { column in
                let fewColumns = uncorrectable.count <= maximumColumnsForErasureSubsets
                guard
                    let corrections = decodeWithAlternatives(
                        difference(column), column: column, suspects: erasures[column], audio: audio, first: first,
                        layout: layout, count: count, alternatives: alternatives)
                        ?? (fewColumns
                            ? decodeWithErasureSubsets(difference(column), suspects: erasures[column], count: count)
                            : nil)
                else { return true }
                record(corrections, column: column)
                return false
            }
        }
        if !uncorrectable.isEmpty {
            return .uncorrectable(
                columns: uncorrectable, columnsWithErrors: columnsWithErrors, checked: CTDBLayout.stride,
                changes: changes)
        }
        if changes.isEmpty {
            return discCRC(of: audio, layout: layout, shift: shift) == crc
                ? .noErrors : .failedCheck(columnsWithErrors: 0, changes: [])
        }
        for change in changes { audio[change.sample] ^= change.mask }
        guard discCRC(of: audio, layout: layout, shift: shift) == crc else {
            for change in changes { audio[change.sample] ^= change.mask }
            return .failedCheck(columnsWithErrors: columnsWithErrors, changes: changes)
        }
        return .repaired(changedSamples: Array(Set(changes.map(\.sample))).sorted())
    }

    /// Syndromes kept spare when decoding with erasures. With e erasures and no other
    /// errors, e syndromes can explain any difference, so without spares a wrong decode
    /// would look right. Each spare makes that about 2^16 times less likely.
    static let spareSyndromes = 2

    /// Decodes one column without its suspect words first: a suspect word that is right
    /// still uses up part of what the syndromes can correct. Uses them only if that fails,
    /// and then keeps `spareSyndromes` syndromes unused (2v + e ≤ count − spares).
    static func decode(_ difference: [UInt16], length: Int, suspects: [Int], count: Int)
        -> [ReedSolomonDecoder.Correction]?
    {
        if let corrections = ReedSolomonDecoder.corrections(syndromes: difference, length: length) {
            return corrections
        }
        let budget = count - spareSyndromes - suspects.count
        guard !suspects.isEmpty, budget >= 0 else { return nil }
        return ReedSolomonDecoder.corrections(
            syndromes: difference, length: length, erasures: suspects, maximumErrors: suspects.count + budget / 2)
    }

    /// Try other versions of suspect words only when at most this many columns fail without them.
    static let maximumColumnsForAlternatives = 256

    /// The most combinations of other versions of a column's suspect words to try.
    static let maximumAlternativeCombinations = 4096

    /// Try subsets of suspect words as erasures only when at most this many columns fail.
    static let maximumColumnsForErasureSubsets = 16

    /// The most subsets of one column's suspect words to try as erasures.
    static let maximumErasureSubsets = 200_000

    /// For a column with more suspect words than its syndromes can erase (with
    /// `spareSyndromes` kept to check the result): tries random subsets of them as
    /// erasures, with no other errors. If every wrong word is in a subset, the subset
    /// decodes, and the spare syndromes show that it does. With the places known, the
    /// error values are the solution of a linear system, so each try is fast. The subsets
    /// come from a fixed seed, so a repair gives the same result each time.
    static func decodeWithErasureSubsets(
        _ difference: [UInt16], suspects: [Int], count: Int
    ) -> [ReedSolomonDecoder.Correction]? {
        let size = count - spareSyndromes
        guard size > 0, suspects.count > size else { return nil }
        var generator = SubsetGenerator(state: UInt64(suspects.count) &* 0x9E37_79B9_7F4A_7C15)
        var pool = suspects
        for _ in 0..<maximumErasureSubsets {
            // The first `size` places after a partial shuffle are a random subset.
            for index in 0..<size { pool.swapAt(index, Int.random(in: index..<pool.count, using: &generator)) }
            let degrees = Array(pool[0..<size])
            if let values = erasureValues(difference, degrees: degrees) {
                return zip(degrees, values).filter { $0.1 != 0 }.map { .init(degree: $0.0, error: $0.1) }
            }
        }
        return nil
    }

    /// The error values at `degrees` that give the syndromes: S_i = Σ_j E_j α^(i d_j). The
    /// first `degrees.count` syndromes give the values (a Vandermonde system); the others
    /// must agree, or the result is nil.
    static func erasureValues(_ syndromes: [UInt16], degrees: [Int]) -> [UInt16]? {
        typealias GF = GaloisField16
        let size = degrees.count
        var matrix = (0..<size).map { row in degrees.map { GF.alphaPower(row * $0) } + [syndromes[row]] }
        for column in 0..<size {
            guard let pivot = (column..<size).first(where: { matrix[$0][column] != 0 }) else { return nil }
            matrix.swapAt(column, pivot)
            let inverse = GF.divide(1, matrix[column][column])
            for k in column...size { matrix[column][k] = GF.multiply(matrix[column][k], inverse) }
            for row in 0..<size where row != column && matrix[row][column] != 0 {
                let factor = matrix[row][column]
                for k in column...size { matrix[row][k] ^= GF.multiply(factor, matrix[column][k]) }
            }
        }
        let values = matrix.map { $0[size] }
        for row in size..<syndromes.count {
            var sum: UInt16 = 0
            for (degree, value) in zip(degrees, values) { sum ^= GF.multiply(value, GF.alphaPower(row * degree)) }
            if sum != syndromes[row] { return nil }
        }
        return values
    }

    /// For a column that cannot be decoded, tries the other versions of its suspect words
    /// that reads gave, fewest changed words first, and decodes again. Changing a word at
    /// degree p by δ changes S_i by δ α^(i p). Returns all changes, as corrections.
    static func decodeWithAlternatives(
        _ difference: [UInt16], column: Int, suspects: [Int], audio: [UInt32], first: Int, layout: CTDBLayout,
        count: Int, alternatives: [Int: [UInt32]]
    ) -> [ReedSolomonDecoder.Correction]? {
        typealias GF = GaloisField16
        let half = column % 2
        // For each suspect word with other versions: the change that each version makes.
        let choices: [(degree: Int, deltas: [UInt16])] = suspects.compactMap { degree in
            let sample = first + (layout.rows - 1 - degree) * CTDBLayout.strideSamples + column / 2
            let word = UInt16(truncatingIfNeeded: audio[sample] >> (16 * half))
            let others = Set((alternatives[sample] ?? []).map { UInt16(truncatingIfNeeded: $0 >> (16 * half)) })
            let deltas = others.subtracting([word]).map { $0 ^ word }.sorted()
            return deltas.isEmpty ? nil : (degree, Array(deltas.prefix(3)))
        }
        guard !choices.isEmpty else { return nil }
        func change(_ delta: UInt16, at degree: Int) -> [UInt16] {
            (0..<count).map { GF.multiply(delta, GF.alphaPower($0 * degree)) }
        }
        let changes = choices.map { choice in choice.deltas.map { change($0, at: choice.degree) } }

        var budget = maximumAlternativeCombinations
        var chosen = [(choice: Int, version: Int)]()
        var found: [ReedSolomonDecoder.Correction]?
        func search(from start: Int, remaining: Int, syndromes: [UInt16]) -> Bool {
            if remaining == 0 {
                budget -= 1
                guard let corrections = decode(syndromes, length: layout.rows, suspects: suspects, count: count)
                else { return false }
                // Combine the chosen versions with the decoder's corrections, degree by degree.
                var errors = [Int: UInt16]()
                for (choice, version) in chosen {
                    errors[choices[choice].degree, default: 0] ^= choices[choice].deltas[version]
                }
                for correction in corrections { errors[correction.degree, default: 0] ^= correction.error }
                found = errors.filter { $0.value != 0 }.map { .init(degree: $0.key, error: $0.value) }
                return true
            }
            for choice in start..<choices.count {
                for version in choices[choice].deltas.indices {
                    guard budget > 0 else { return false }
                    chosen.append((choice, version))
                    let changed = zip(syndromes, changes[choice][version]).map { $0 ^ $1 }
                    if search(from: choice + 1, remaining: remaining - 1, syndromes: changed) { return true }
                    chosen.removeLast()
                }
            }
            return false
        }
        for size in 1...choices.count where budget > 0 {
            if search(from: 0, remaining: size, syndromes: difference) { return found }
        }
        return nil
    }

    /// For each column, the degrees of its words that fall in `suspects`.
    static func erasureDegrees(for suspects: [Range<Int>], layout: CTDBLayout, shift: Int) -> [[Int]] {
        var erasures = [[Int]](repeating: [], count: CTDBLayout.stride)
        let first = layout.prefixSamples + shift
        let end = first + layout.rows * CTDBLayout.strideSamples
        for range in suspects {
            for sample in range.clamped(to: first..<end) {
                let position = sample - first
                let degree = layout.rows - 1 - position / CTDBLayout.strideSamples
                let column = 2 * (position % CTDBLayout.strideSamples)
                erasures[column].append(degree)
                erasures[column + 1].append(degree)
            }
        }
        return erasures
    }

    /// The samples of a column that fall in `suspects`: where more reads could help.
    public static func suspectSamples(
        inColumn column: Int, suspects: [Range<Int>], layout: CTDBLayout, shift: Int
    ) -> [Int] {
        let first = layout.prefixSamples + shift
        let end = first + layout.rows * CTDBLayout.strideSamples
        var samples = [Int]()
        for range in suspects {
            for sample in range.clamped(to: first..<end)
            where 2 * ((sample - first) % CTDBLayout.strideSamples) == column - column % 2 {
                samples.append(sample)
            }
        }
        return samples
    }
}

/// SplitMix64, for the erasure subsets: fast, and the same on every run.
private struct SubsetGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
