/// CD+G graphics (karaoke lyrics, pictures) in the R–W subchannels of the audio sectors.
///
/// The raw P–W subchannel has 96 bytes a sector; R to W are bits 5 to 0 of each, so a sector
/// holds four packs of 24 six-bit symbols. The packs are interleaved as the Red Book says:
/// symbol i of a pack comes from symbol s(i) of the pack s(i) mod 8 later, where s swaps
/// 1↔18, 2↔5, and 3↔23 (checked on a real CD+G disc, 2026-10-29). A pack of graphics has
/// command 9 (TV graphics, mode 1 item 1) and one of the instructions below; CD+EG's have
/// command 10 (extended TV graphics, mode 1 item 2).
public enum CDGraphics {
    /// The instructions of TV-graphics mode: memory preset, border preset, tile block,
    /// scroll preset, scroll copy, transparent color, the color tables, and tile block XOR.
    static let instructions: Set<UInt8> = [1, 2, 6, 20, 24, 28, 30, 31, 38]

    /// The R–W packs of raw P–W subchannel, de-interleaved: 24 six-bit symbols each.
    static func packs(_ pw: [UInt8]) -> [[UInt8]] {
        let raw = stride(from: 0, to: pw.count - 23, by: 24).map { start in pw[start..<(start + 24)].map { $0 & 0x3F } }
        func swapped(_ index: Int) -> Int {
            switch index {
            case 1: 18
            case 18: 1
            case 2: 5
            case 5: 2
            case 3: 23
            case 23: 3
            default: index
            }
        }
        guard raw.count > 7 else { return [] }
        return (0..<(raw.count - 7)).map { pack in
            (0..<24).map { index in
                let from = swapped(index)
                return raw[pack + from % 8][from]
            }
        }
    }

    /// True if the subchannel holds CD+G graphics: at least 8 packs of command 9, and 9 of 10
    /// of them with an instruction that CD+G has. Damaged or made-up subchannel has command 9
    /// in about 1 pack of 64, and a valid instruction in about 1 of 7 of those.
    public static func holdsGraphics(_ pw: [UInt8]) -> Bool {
        holds(packs(pw), command: 9, instructions: instructions)
    }

    /// The instructions of extended TV-graphics mode (CD+EG) that its discs use: memory
    /// control (3), the tile blocks (6 and 14), and the color tables (16 and 17), the only ones
    /// in more than 1 command-10 pack of 100 in the subchannel of four CD+EG discs (2026-11-01).
    static let extendedInstructions: Set<UInt8> = [3, 6, 14, 16, 17]

    /// True if the subchannel holds CD+EG graphics (CD+Extended Graphics: 256 colors and a
    /// second plane), in packs of command 10, by the same rule as `holdsGraphics(_:)`. A CD+EG
    /// disc also carries CD+G graphics, for players that have only CD+G, and its command-10
    /// packs can be missing for minutes at a time (`DiscProbe` looks in every track).
    public static func holdsExtendedGraphics(_ pw: [UInt8]) -> Bool {
        holds(packs(pw), command: 10, instructions: extendedInstructions)
    }

    /// True if a CD+EG pack makes a CD+EG player show something that a CD+G player does not:
    /// a font or color of its own, or a MEMORY control (DM in bits 3 and 2, WM in 1 and 0)
    /// for the 1-plane state, for showing the SECONDARY or both, or for drawing the CD+G
    /// instructions somewhere other than the PRIMARY, which a CD+G player still draws there.
    /// DM 01 with WM 01 is CD+G's own state, and WM 11 draws in the PRIMARY too.
    static func changesPicture(_ pack: [UInt8]) -> Bool {
        guard pack.count >= 5, pack[0] & 0x3F == 10 else { return false }
        let instruction = pack[1] & 0x3F
        guard instruction == 3 else { return [6, 14].contains(instruction) || (16...63).contains(instruction) }
        let (mode, memory) = ((pack[4] >> 2) & 3, pack[4] & 3)
        // DM 00 with WM 01 or 10: no operation.
        if mode == 0 { return memory == 0 || memory == 3 }
        return mode != 1 || memory & 1 == 0
    }

    static func holds(_ packs: [[UInt8]], command: UInt8, instructions: Set<UInt8>) -> Bool {
        let graphics = packs.filter { $0[0] == command }
        let valid = graphics.filter { instructions.contains($0[1]) }.count
        return graphics.count >= 8 && valid * 10 >= graphics.count * 9
    }
}

// MARK: - Parity

extension CDGraphics {
    /// What a pack's parity says about it.
    public enum PackCheck: Equatable, Sendable {
        /// The parity holds: the pack is as written.
        case valid
        /// One symbol was wrong, and the parity put it right.
        case corrected
        /// Two symbols were wrong, and the parity put them right, or so it seems: a pack with
        /// three or more wrong symbols comes out this way too, as another valid pack, about 1
        /// time in 20. Take it when a read again gives the same pack.
        case correctedTwoSymbols
        /// More symbols were wrong than the parity can correct.
        case uncorrectable
    }

    /// GF(2⁶), with the polynomial x⁶ + x + 1 and α = 2: the field of the R–W parity.
    enum GF64 {
        static let exp: [UInt8] = {
            var table = [UInt8](repeating: 0, count: 126)
            var x = 1
            for i in 0..<63 {
                table[i] = UInt8(x)
                table[i + 63] = UInt8(x)
                x <<= 1
                if x & 0x40 != 0 { x ^= 0b100_0011 }
            }
            return table
        }()
        static let log: [Int] = {
            var table = [Int](repeating: 0, count: 64)
            for i in 0..<63 { table[Int(exp[i])] = i }
            return table
        }()
        static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
            a == 0 || b == 0 ? 0 : exp[log[Int(a)] + log[Int(b)]]
        }
        static func divide(_ a: UInt8, _ b: UInt8) -> UInt8 {
            a == 0 ? 0 : exp[(log[Int(a)] - log[Int(b)] + 63) % 63]
        }
        static func power(_ e: Int) -> UInt8 { exp[e % 63] }
    }

    /// The syndromes S_j = Σ s_i α^(j × degree) of a codeword, j from 0, its first symbol at the
    /// highest degree: all zero when the parity holds.
    static func syndromes(_ symbols: ArraySlice<UInt8>, count: Int) -> [UInt8] {
        let last = symbols.count - 1
        return (0..<count).map { j in
            var sum: UInt8 = 0
            for (i, symbol) in symbols.enumerated() where symbol != 0 {
                sum ^= GF64.multiply(symbol, GF64.power(j * (last - i)))
            }
            return sum
        }
    }

    /// `symbols` with `parity` parity symbols after them, so that the syndromes are zero: Reed–
    /// Solomon over GF(2⁶) with the generator Π (x + α^j), j from 0 to `parity` − 1.
    static func addingParity(_ symbols: [UInt8], parity: Int) -> [UInt8] {
        var generator: [UInt8] = [1]
        for j in 0..<parity {
            var product = generator + [0]
            for i in generator.indices { product[i + 1] ^= GF64.multiply(generator[i], GF64.power(j)) }
            generator = product
        }
        var remainder = symbols + [UInt8](repeating: 0, count: parity)
        for i in symbols.indices where remainder[i] != 0 {
            let factor = remainder[i]
            for k in generator.indices { remainder[i + k] ^= GF64.multiply(generator[k], factor) }
        }
        return symbols + remainder.suffix(parity)
    }

    /// A pack with its parity, as a disc has it: Q parity (symbols 2 and 3) over the command
    /// and the instruction, then P parity (symbols 20 to 23) over the first 20.
    static func pack(command: UInt8, instruction: UInt8, data: [UInt8]) -> [UInt8] {
        precondition(data.count == 16)
        return addingParity(addingParity([command, instruction], parity: 2) + data, parity: 4)
    }

    /// Checks a pack by its P parity (the Red Book's Reed–Solomon (24, 20) code, symbols 20 to
    /// 23), and corrects one or two wrong symbols. A correction must also leave the Q parity
    /// of the command and instruction (symbols 2 and 3) holding, which turns away the
    /// miscorrections that change those. A drive gives the subchannel without the error
    /// correction of the audio, so single wrong symbols are common: 456 of the 64,212 packs
    /// of a CD+EG CD-R's track 1 in the ASUS (2026-11-02), each with one or two. A correction
    /// of two can be wrong (`correctedTwoSymbols`): in a CD-RW of *Amadeus* (VINY-2) read in
    /// the MATSHITA (2026-11-05), 4 of about 115 packs with more wrong symbols came out as
    /// other valid packs, 3 of them tiles drawn wrong.
    public static func check(_ pack: inout [UInt8]) -> PackCheck {
        let s = syndromes(pack[...], count: 4)
        guard s.contains(where: { $0 != 0 }) else { return .valid }
        func headerHolds(_ candidate: [UInt8]) -> Bool {
            !syndromes(candidate[0..<4], count: 2).contains { $0 != 0 }
        }
        func fits(_ errors: [(degree: Int, value: UInt8)]) -> Bool {
            (1..<4).allSatisfy { j in
                errors.reduce(0) { $0 ^ GF64.multiply($1.value, GF64.power(j * $1.degree)) } == s[j]
            }
        }
        func apply(_ errors: [(degree: Int, value: UInt8)]) -> Bool {
            var candidate = pack
            for error in errors { candidate[23 - error.degree] ^= error.value }
            guard headerHolds(candidate) else { return false }
            pack = candidate
            return true
        }
        // One wrong symbol at degree d, by e: S_j = e α^(jd).
        if s[0] != 0 {
            for d in 0..<24 where fits([(d, s[0])]) {
                return apply([(d, s[0])]) ? .corrected : .uncorrectable
            }
        }
        // Two, at d1 and d2: e1 + e2 = S0, and e1 X1 + e2 X2 = S1.
        for d1 in 0..<24 {
            for d2 in (d1 + 1)..<24 {
                let x1 = GF64.power(d1)
                let x2 = GF64.power(d2)
                let e2 = GF64.divide(s[1] ^ GF64.multiply(s[0], x1), x1 ^ x2)
                let e1 = s[0] ^ e2
                guard e1 != 0, e2 != 0 else { continue }
                let errors = [(degree: d1, value: e1), (degree: d2, value: e2)]
                if fits(errors) { return apply(errors) ? .correctedTwoSymbols : .uncorrectable }
            }
        }
        return .uncorrectable
    }

    /// Packs of a stretch of subchannel, checked by their parity.
    public struct CheckedPacks: Equatable, Sendable {
        /// The packs, 24 six-bit symbols each, with the wrong symbols put right. A pack that
        /// could not be corrected is all zeros, which a player passes over, so that no damaged
        /// tile is drawn.
        public var packs: [[UInt8]]
        public var corrected = 0
        public var uncorrectable = 0
    }

    /// The packs of raw P–W subchannel (`packs(_:)`), checked and corrected (`check(_:)`). One
    /// read has nothing to compare, so a correction of two symbols is taken as it is;
    /// `CDGraphicsReader` reads such a pack again.
    public static func checkedPacks(_ pw: [UInt8]) -> CheckedPacks { checked(packs(pw)) }

    /// `packs`, checked and corrected (`check(_:)`).
    static func checked(_ packs: [[UInt8]]) -> CheckedPacks {
        var result = CheckedPacks(packs: packs)
        for i in result.packs.indices {
            switch check(&result.packs[i]) {
            case .valid: break
            case .corrected, .correctedTwoSymbols: result.corrected += 1
            case .uncorrectable:
                result.uncorrectable += 1
                result.packs[i] = [UInt8](repeating: 0, count: 24)
            }
        }
        return result
    }
}
