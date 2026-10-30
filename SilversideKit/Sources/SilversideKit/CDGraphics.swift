/// CD+G graphics (karaoke lyrics, pictures) in the R–W subchannels of the audio sectors.
///
/// The raw P–W subchannel has 96 bytes a sector; R to W are bits 5 to 0 of each, so a sector
/// holds four packs of 24 six-bit symbols. The packs are interleaved as the Red Book says:
/// symbol i of a pack comes from symbol s(i) of the pack s(i) mod 8 later, where s swaps
/// 1↔18, 2↔5, and 3↔23 (checked on a real CD+G disc, 2026-10-29). A pack of graphics has
/// command 9 (TV graphics, mode 1 item 1) and one of the instructions below.
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
        let graphics = packs(pw).filter { $0[0] == 9 }
        let valid = graphics.filter { instructions.contains($0[1]) }.count
        return graphics.count >= 8 && valid * 10 >= graphics.count * 9
    }
}
