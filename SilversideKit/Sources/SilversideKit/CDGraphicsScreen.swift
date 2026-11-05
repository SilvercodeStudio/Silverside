/// The screen of a CD+G player, drawn pack by pack from a disc's graphics (`CDGraphicsReader`'s
/// `.cdg` files): 300 × 216 pixels, each one of 16 colors from a table of 4,096 (4 bits each
/// of red, green, and blue). The outer 6 pixels at the left and right and 12 at the top and
/// bottom are the border. Pictures are drawn in tiles of 6 × 12 pixels, 50 across and 18 down.
///
/// A CD+G player draws CD+G's packs (command 9, ITEM-1) only, and passes over CD+EG's
/// (command 10, ITEM-2). With `extended`, the screen is a CD+EG player's (IEC 60908 clause
/// 23, as the Divacore notes reproduce it): a second memory of 4-bit pixels, the SECONDARY,
/// beside the CD+G picture, the PRIMARY. MEMORY control (ITEM-2 instruction 3) chooses what
/// shows (DM) and which memory the CD+G instructions draw in (WM). In the 1-plane state (DM
/// 00) each pixel is an 8-bit color, the SECONDARY's 4 bits above the PRIMARY's, from a table
/// of 256 colors with 6 bits each of red, green, and blue; the CD+G instructions draw in the
/// PRIMARY, and CD+EG's own font instructions in the SECONDARY. In the 2-plane state the two
/// memories are 16-color pictures, each with its 16 colors, shown alone (DM 01, 10) or
/// added (DM 11). A player starts as a CD+G player: DM 01, WM 01. A disc with no CD+EG
/// packs draws the same either way.
public struct CDGraphicsScreen: Equatable, Sendable {
    public static let width = 300
    public static let height = 216
    static let tileWidth = 6
    static let tileHeight = 12

    /// True for a CD+EG player, false for a CD+G player.
    public let extended: Bool
    /// Each pixel's color, an index into `colors`, row by row: the PRIMARY memory, the CD+G picture.
    public private(set) var pixels = [UInt8](repeating: 0, count: width * height)
    /// The SECONDARY memory, the CD+EG layer: zeros on a CD+G player.
    public private(set) var secondary = [UInt8](repeating: 0, count: width * height)
    /// The color table: 12-bit colors, red in bits 11 to 8, green 7 to 4, blue 3 to 0. A
    /// player starts with every color black.
    public private(set) var colors = [UInt16](repeating: 0, count: 16)
    /// CD+EG's table of 256 colors, as shown: 18-bit colors, red in bits 17 to 12, green 11
    /// to 6, blue 5 to 0. Its first 16 are the SECONDARY's colors in the 2-plane state.
    public private(set) var extendedColors = [UInt32](repeating: 0, count: 256)
    /// The table as loaded: it shows from the next MEMORY control (clause 23.5.1).
    private var loadedColors = [UInt32](repeating: 0, count: 256)
    /// MEMORY control's display mode: 0 the 1-plane state, 1 PRIMARY, 2 SECONDARY, 3 both added.
    public private(set) var displayMode = 1
    /// MEMORY control's working memory for the CD+G instructions: bit 0 PRIMARY, bit 1 SECONDARY.
    public private(set) var workingMemory = 1
    /// The fine scroll, in pixels: how far the picture is moved right (0 to 5) and down (0 to 11).
    public private(set) var horizontalOffset = 0
    public private(set) var verticalOffset = 0
    /// Counts the packs that changed what the screen shows, so that a video can tell when a
    /// frame is the same as the one before.
    public private(set) var changes = 0

    public init(extended: Bool = false) {
        self.extended = extended
    }

    /// The memories that the CD+G instructions draw in: PRIMARY only on a CD+G player, and in
    /// the 1-plane state (where WM 00 draws in none); else as WM says.
    private var targets: (primary: Bool, secondary: Bool) {
        guard extended else { return (true, false) }
        if displayMode == 0 { return (workingMemory != 0, false) }
        return (workingMemory & 1 != 0, workingMemory & 2 != 0)
    }

    /// Draws one pack: 24 six-bit symbols, the command in symbol 0, the instruction in 1,
    /// and the data in 4 to 19.
    public mutating func apply(_ pack: ArraySlice<UInt8>) {
        let base = pack.startIndex
        guard pack.count >= 20 else { return }
        let command = pack[base] & 0x3F
        let data = (0..<16).map { pack[base + 4 + $0] & 0x3F }
        let instruction = pack[base + 1] & 0x3F
        if command == 9 {
            let (primary, secondary) = targets
            guard primary || secondary else { return }
            if [1, 2, 6, 38, 20, 24, 30, 31].contains(instruction) { changes += 1 }
            switch instruction {
            case 1: preset(color: data[0] & 0x0F, repeat: Int(data[1] & 0x0F), primary: primary, secondary: secondary)
            case 2: border(color: data[0] & 0x0F, primary: primary, secondary: secondary)
            case 6, 38:
                if primary { Self.tile(data, xor: instruction == 38, into: &pixels) }
                if secondary { Self.tile(data, xor: instruction == 38, into: &self.secondary) }
            case 20, 24: scroll(data, wraps: instruction == 24, primary: primary, secondary: secondary)
            case 30, 31:
                let first = instruction == 30 ? 0 : 8
                let loaded = Self.colors12(data)
                if primary { colors.replaceSubrange(first..<(first + 8), with: loaded) }
                // The SECONDARY's 16 colors are the first of the 256, 4 bits a channel.
                if secondary {
                    for (i, color) in loaded.enumerated() {
                        extendedColors[first + i] = Self.upper(color, over: extendedColors[first + i])
                        loadedColors[first + i] = extendedColors[first + i]
                    }
                }
            default: break  // 28, the transparent color, is for a picture over video
            }
        } else if command == 10, extended {
            applyExtended(instruction, data)
        }
    }

    public mutating func apply(_ pack: [UInt8]) { apply(pack[...]) }

    /// CD+EG's instructions (clause 23.5). All but MEMORY control and the first two color
    /// loads work in the 1-plane state only.
    private mutating func applyExtended(_ instruction: UInt8, _ data: [UInt8]) {
        switch instruction {
        case 3:
            // DM in bits 3 and 2, WM in 1 and 0, in every data symbol; a Sega Saturn reads symbol 4.
            let (mode, memory) = (Int(data[0] >> 2) & 3, Int(data[0]) & 3)
            // DM 00 with WM 01 or 10: no operation; the last MEMORY control stays.
            guard mode != 0 || memory == 0 || memory == 3 else { return }
            displayMode = mode
            workingMemory = memory
            // It ends a chain of color loads, and shows them.
            extendedColors = loadedColors
            changes += 1
        case 16...47:
            guard displayMode == 0 || instruction <= 17 else { return }
            let first = Int(instruction - 16) * 8
            for (i, color) in Self.colors12(data).enumerated() {
                loadedColors[first + i] = Self.upper(color, over: loadedColors[first + i])
            }
            // In the 2-plane state they are the SECONDARY's colors (clause 23.5 makes these two
            // work in both states), and show at once, as CD+G's do.
            if displayMode != 0 {
                for i in first..<(first + 8) { extendedColors[i] = loadedColors[i] }
                changes += 1
            }
        case 48...63:
            guard displayMode == 0 else { return }
            // 16 colors, one symbol each: the low 2 bits of red, green, and blue.
            let first = Int(instruction - 48) * 16
            for i in 0..<16 {
                let low = UInt32(data[i])
                let (r, g, b) = ((low >> 4) & 3, (low >> 2) & 3, low & 3)
                loadedColors[first + i] = (loadedColors[first + i] & 0x3C_F3C) | r << 12 | g << 6 | b
            }
        case 6, 14:
            guard displayMode == 0 else { return }
            changes += 1
            Self.tile(data, xor: instruction == 14, into: &secondary)
        default: break
        }
    }

    /// A 12-bit color as the upper 4 bits of an 18-bit one, keeping its lower 2 bits.
    private static func upper(_ color: UInt16, over old: UInt32) -> UInt32 {
        let (r, g, b) = (UInt32(color >> 8) & 0xF, UInt32(color >> 4) & 0xF, UInt32(color) & 0xF)
        return (old & 0x03_0C3) | r << 14 | g << 8 | b << 2
    }

    /// Memory preset: every pixel, the border too, takes the color. A disc sends it several
    /// times in a row, counted by `repeat`, so that a damaged one does not matter, and a player
    /// clears for the first only (repeat 0, as FFmpeg does): *The Four Seasons* (VINY-1) has a
    /// lone preset with repeat 6 in track 1, which a player passes over. In the 1-plane state
    /// the SECONDARY takes 0 (clause 23.5.1).
    private mutating func preset(color: UInt8, repeat count: Int, primary: Bool, secondary: Bool) {
        guard count == 0 else { return }
        if primary { for i in pixels.indices { pixels[i] = color } }
        if secondary || (extended && displayMode == 0) {
            let value = displayMode == 0 ? 0 : color
            for i in self.secondary.indices { self.secondary[i] = value }
        }
    }

    /// Border preset: the border takes the color.
    private mutating func border(color: UInt8, primary: Bool, secondary: Bool) {
        let (w, h, tw, th) = (Self.width, Self.height, Self.tileWidth, Self.tileHeight)
        let clearsSecondary = secondary || (extended && displayMode == 0)
        let value = displayMode == 0 ? 0 : color
        for y in 0..<h {
            for x in 0..<w where x < tw || x >= w - tw || y < th || y >= h - th {
                if primary { pixels[y * w + x] = color }
                if clearsSecondary { self.secondary[y * w + x] = value }
            }
        }
    }

    /// Tile block: 6 × 12 pixels at a row (0 to 17) and column (0 to 49), each pixel the
    /// second color where its bit is set and the first where not, or with `xor`, the colors'
    /// indexes XORed into the pixels. CD+EG's font instructions have the same layout.
    private static func tile(_ data: [UInt8], xor: Bool, into pixels: inout [UInt8]) {
        let colors = [data[0] & 0x0F, data[1] & 0x0F]
        let row = Int(data[2] & 0x1F)
        let column = Int(data[3] & 0x3F)
        guard row < height / tileHeight, column < width / tileWidth else { return }
        for line in 0..<tileHeight {
            let bits = data[4 + line]
            let start = (row * tileHeight + line) * width + column * tileWidth
            for x in 0..<tileWidth {
                let color = colors[Int(bits >> (5 - x)) & 1]
                pixels[start + x] = xor ? pixels[start + x] ^ color : color
            }
        }
    }

    /// Scroll preset or copy: the fine offsets, and a move by a whole tile, right or left
    /// (1 or 2 in bits 5 and 4 of the second data symbol) and down or up (the third). What
    /// moves off one edge comes in at the other (copy) or the space left takes the color
    /// (preset). In the 1-plane state both memories move, and the SECONDARY's space takes 0.
    private mutating func scroll(_ data: [UInt8], wraps: Bool, primary: Bool, secondary: Bool) {
        let color = data[0] & 0x0F
        let horizontal = Int(data[1] >> 4) & 0x03
        let vertical = Int(data[2] >> 4) & 0x03
        horizontalOffset = min(Int(data[1] & 0x07), Self.tileWidth - 1)
        verticalOffset = min(Int(data[2] & 0x0F), Self.tileHeight - 1)
        let dx = horizontal == 1 ? Self.tileWidth : horizontal == 2 ? -Self.tileWidth : 0
        let dy = vertical == 1 ? Self.tileHeight : vertical == 2 ? -Self.tileHeight : 0
        guard dx != 0 || dy != 0 else { return }
        if primary { Self.move(&pixels, dx: dx, dy: dy, wraps: wraps, fill: color) }
        if secondary || (extended && displayMode == 0) {
            Self.move(&self.secondary, dx: dx, dy: dy, wraps: wraps, fill: displayMode == 0 ? 0 : color)
        }
    }

    private static func move(_ pixels: inout [UInt8], dx: Int, dy: Int, wraps: Bool, fill: UInt8) {
        let (w, h) = (width, height)
        var moved = [UInt8](repeating: fill, count: pixels.count)
        for y in 0..<h {
            for x in 0..<w {
                var (tx, ty) = (x + dx, y + dy)
                if wraps {
                    tx = (tx + w) % w
                    ty = (ty + h) % h
                } else if tx < 0 || tx >= w || ty < 0 || ty >= h {
                    continue
                }
                moved[ty * w + tx] = pixels[y * w + x]
            }
        }
        pixels = moved
    }

    /// Load color table: 8 colors, two symbols each: red in bits 5 to 2 of the first, green in
    /// its bits 1 and 0 and bits 5 and 4 of the second, and blue in the second's bits 3 to 0.
    private static func colors12(_ data: [UInt8]) -> [UInt16] {
        (0..<8).map { i in
            let (high, low) = (UInt16(data[2 * i]), UInt16(data[2 * i + 1]))
            let red = (high >> 2) & 0x0F
            let green = ((high & 0x03) << 2) | ((low >> 4) & 0x03)
            let blue = low & 0x0F
            return red << 8 | green << 4 | blue
        }
    }

    /// The color of each 8-bit index `secondary << 4 | primary`, as 8-bit red, green, and blue
    /// in the display mode: the 256 colors (1-plane state); the PRIMARY's 16 or the
    /// SECONDARY's; or the two added, each channel at most full.
    private func palette() -> [(UInt8, UInt8, UInt8)] {
        func rgb12(_ color: UInt16) -> (Int, Int, Int) {
            (Int((color >> 8) & 0xF) * 17, Int((color >> 4) & 0xF) * 17, Int(color & 0xF) * 17)
        }
        func rgb18(_ color: UInt32) -> (Int, Int, Int) {
            func eight(_ v: UInt32) -> Int { Int((v << 2) | (v >> 4)) }
            return (eight((color >> 12) & 0x3F), eight((color >> 6) & 0x3F), eight(color & 0x3F))
        }
        // The 2-plane state's colors have 4 bits a channel: the upper 4 of the 6.
        func secondary(_ index: Int) -> (Int, Int, Int) {
            let color = extendedColors[index]
            return rgb12(
                UInt16((color >> 14) & 0xF) << 8 | UInt16((color >> 8) & 0xF) << 4 | UInt16((color >> 2) & 0xF))
        }
        let mode = extended ? displayMode : 1
        return (0..<256).map { index in
            let (low, high) = (index & 0x0F, index >> 4)
            let color: (Int, Int, Int)
            switch mode {
            case 0: color = rgb18(extendedColors[index])
            case 1: color = rgb12(colors[low])
            case 2: color = secondary(high)
            default:
                let (a, b) = (rgb12(colors[low]), secondary(high))
                color = (min(a.0 + b.0, 255), min(a.1 + b.1, 255), min(a.2 + b.2, 255))
            }
            return (UInt8(color.0), UInt8(color.1), UInt8(color.2))
        }
    }

    /// Each pixel shown, as an index into `palette()`, row by row: the border as it is, and
    /// inside it the picture moved by the fine scroll.
    private func shown(_ body: (_ x: Int, _ y: Int, _ index: Int) -> Void) {
        let (w, h, tw, th) = (Self.width, Self.height, Self.tileWidth, Self.tileHeight)
        pixels.withUnsafeBufferPointer { primary in
            secondary.withUnsafeBufferPointer { secondary in
                for y in 0..<h {
                    for x in 0..<w {
                        let inside = x >= tw && x < w - tw && y >= th && y < h - th
                        let source = min(
                            inside ? (y + verticalOffset) * w + x + horizontalOffset : y * w + x, primary.count - 1)
                        body(x, y, Int(secondary[source]) << 4 | Int(primary[source]))
                    }
                }
            }
        }
    }

    /// Draws the picture as a player shows it (`rgb()`) into a 32-bit BGRA image, each pixel
    /// `scale` × `scale` pixels there: `base` is its first row, at least `width × scale` pixels
    /// wide and `height × scale` rows high.
    public func drawBGRA(into base: UnsafeMutableRawPointer, bytesPerRow: Int, scale: Int) {
        let palette = palette().map { r, g, b in
            (0xFF00_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)).littleEndian
        }
        var row = [UInt32](repeating: 0, count: Self.width * scale)
        shown { x, y, index in
            let color = palette[index]
            for i in 0..<scale { row[x * scale + i] = color }
            guard x == Self.width - 1 else { return }
            row.withUnsafeBytes { bytes in
                for i in 0..<scale {
                    (base + (y * scale + i) * bytesPerRow).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
                }
            }
        }
    }

    /// The picture as a player shows it, 8-bit red, green, and blue for each pixel, row by
    /// row: the border as it is, and inside it the picture moved by the fine scroll.
    public func rgb() -> [UInt8] {
        let palette = palette()
        var out = [UInt8](repeating: 0, count: Self.width * Self.height * 3)
        shown { x, y, index in
            let (r, g, b) = palette[index]
            let at = (y * Self.width + x) * 3
            out[at] = r
            out[at + 1] = g
            out[at + 2] = b
        }
        return out
    }
}
