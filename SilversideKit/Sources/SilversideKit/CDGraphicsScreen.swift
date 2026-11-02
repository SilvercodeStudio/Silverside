/// The screen of a CD+G player, drawn pack by pack from a disc's graphics (`CDGraphicsReader`'s
/// `.cdg` files): 300 × 216 pixels, each one of 16 colors from a table of 4,096 (4 bits each
/// of red, green, and blue). The outer 6 pixels at the left and right and 12 at the top and
/// bottom are the border. Pictures are drawn in tiles of 6 × 12 pixels, 50 across and 18 down.
/// Only CD+G's packs (command 9) draw; CD+EG's (command 10) are passed over, as a CD+G
/// player does.
public struct CDGraphicsScreen: Equatable, Sendable {
    public static let width = 300
    public static let height = 216
    static let tileWidth = 6
    static let tileHeight = 12

    /// Each pixel's color, an index into `colors`, row by row.
    public private(set) var pixels = [UInt8](repeating: 0, count: width * height)
    /// The color table: 12-bit colors, red in bits 11 to 8, green 7 to 4, blue 3 to 0. A
    /// player starts with every color black.
    public private(set) var colors = [UInt16](repeating: 0, count: 16)
    /// The fine scroll, in pixels: how far the picture is moved right (0 to 5) and down (0 to 11).
    public private(set) var horizontalOffset = 0
    public private(set) var verticalOffset = 0
    /// Counts the packs that changed what the screen shows, so that a video can tell when a
    /// frame is the same as the one before.
    public private(set) var changes = 0

    public init() {}

    /// Draws one pack: 24 six-bit symbols, the command in symbol 0, the instruction in 1,
    /// and the data in 4 to 19.
    public mutating func apply(_ pack: ArraySlice<UInt8>) {
        let base = pack.startIndex
        guard pack.count >= 20, pack[base] & 0x3F == 9 else { return }
        let data = (0..<16).map { pack[base + 4 + $0] & 0x3F }
        let instruction = pack[base + 1] & 0x3F
        if [1, 2, 6, 38, 20, 24, 30, 31].contains(instruction) { changes += 1 }
        switch instruction {
        case 1: preset(color: data[0] & 0x0F, repeat: Int(data[1] & 0x0F))
        case 2: border(color: data[0] & 0x0F)
        case 6: tile(data, xor: false)
        case 38: tile(data, xor: true)
        case 20: scroll(data, wraps: false)
        case 24: scroll(data, wraps: true)
        case 30: loadColors(data, from: 0)
        case 31: loadColors(data, from: 8)
        default: break  // 28, the transparent color, is for a picture over video
        }
    }

    public mutating func apply(_ pack: [UInt8]) { apply(pack[...]) }

    /// Memory preset: every pixel, the border too, takes the color. A disc sends it several
    /// times in a row, counted by `repeat`, so that a damaged one does not matter, and a player
    /// clears for the first only (repeat 0, as FFmpeg does): *The Four Seasons* (VINY-1) has a
    /// lone preset with repeat 6 in track 1, which a player passes over.
    private mutating func preset(color: UInt8, repeat count: Int) {
        guard count == 0 else { return }
        for i in pixels.indices { pixels[i] = color }
    }

    /// Border preset: the border takes the color.
    private mutating func border(color: UInt8) {
        let (w, h, tw, th) = (Self.width, Self.height, Self.tileWidth, Self.tileHeight)
        for y in 0..<h {
            for x in 0..<w where x < tw || x >= w - tw || y < th || y >= h - th { pixels[y * w + x] = color }
        }
    }

    /// Tile block: 6 × 12 pixels at a row (0 to 17) and column (0 to 49), each pixel the
    /// second color where its bit is set and the first where not, or with `xor`, the colors'
    /// indexes XORed into the pixels.
    private mutating func tile(_ data: [UInt8], xor: Bool) {
        let colors = [data[0] & 0x0F, data[1] & 0x0F]
        let row = Int(data[2] & 0x1F)
        let column = Int(data[3] & 0x3F)
        guard row < Self.height / Self.tileHeight, column < Self.width / Self.tileWidth else { return }
        for line in 0..<Self.tileHeight {
            let bits = data[4 + line]
            let start = (row * Self.tileHeight + line) * Self.width + column * Self.tileWidth
            for x in 0..<Self.tileWidth {
                let color = colors[Int(bits >> (5 - x)) & 1]
                pixels[start + x] = xor ? pixels[start + x] ^ color : color
            }
        }
    }

    /// Scroll preset or copy: the fine offsets, and a move by a whole tile, right or left
    /// (1 or 2 in bits 5 and 4 of the second data symbol) and down or up (the third). What
    /// moves off one edge comes in at the other (copy) or the space left takes the color
    /// (preset).
    private mutating func scroll(_ data: [UInt8], wraps: Bool) {
        let color = data[0] & 0x0F
        let horizontal = Int(data[1] >> 4) & 0x03
        let vertical = Int(data[2] >> 4) & 0x03
        horizontalOffset = min(Int(data[1] & 0x07), Self.tileWidth - 1)
        verticalOffset = min(Int(data[2] & 0x0F), Self.tileHeight - 1)
        let dx = horizontal == 1 ? Self.tileWidth : horizontal == 2 ? -Self.tileWidth : 0
        let dy = vertical == 1 ? Self.tileHeight : vertical == 2 ? -Self.tileHeight : 0
        guard dx != 0 || dy != 0 else { return }
        let (w, h) = (Self.width, Self.height)
        var moved = [UInt8](repeating: color, count: pixels.count)
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

    /// Load color table: 8 colors, from entry 0 or 8, two symbols each: red in bits 5 to 2 of
    /// the first, green in its bits 1 and 0 and bits 5 and 4 of the second, and blue in the
    /// second's bits 3 to 0.
    private mutating func loadColors(_ data: [UInt8], from first: Int) {
        for i in 0..<8 {
            let (high, low) = (UInt16(data[2 * i]), UInt16(data[2 * i + 1]))
            let red = (high >> 2) & 0x0F
            let green = ((high & 0x03) << 2) | ((low >> 4) & 0x03)
            let blue = low & 0x0F
            colors[first + i] = red << 8 | green << 4 | blue
        }
    }

    /// Draws the picture as a player shows it (`rgb()`) into a 32-bit BGRA image, each pixel
    /// `scale` × `scale` pixels there: `base` is its first row, at least `width × scale` pixels
    /// wide and `height × scale` rows high.
    public func drawBGRA(into base: UnsafeMutableRawPointer, bytesPerRow: Int, scale: Int) {
        let (w, h, tw, th) = (Self.width, Self.height, Self.tileWidth, Self.tileHeight)
        let palette = colors.map { color -> UInt32 in
            let (r, g, b) = (
                UInt32((color >> 8) & 0x0F) * 17, UInt32((color >> 4) & 0x0F) * 17, UInt32(color & 0x0F) * 17
            )
            return 0xFF00_0000 | r << 16 | g << 8 | b
        }
        var row = [UInt32](repeating: 0, count: w * scale)
        pixels.withUnsafeBufferPointer { pixels in
            for y in 0..<h {
                for x in 0..<w {
                    let inside = x >= tw && x < w - tw && y >= th && y < h - th
                    let source = inside ? (y + verticalOffset) * w + x + horizontalOffset : y * w + x
                    let color = palette[Int(pixels[min(source, pixels.count - 1)])]
                    for i in 0..<scale { row[x * scale + i] = color.littleEndian }
                }
                row.withUnsafeBytes { bytes in
                    for i in 0..<scale {
                        (base + (y * scale + i) * bytesPerRow).copyMemory(
                            from: bytes.baseAddress!, byteCount: bytes.count)
                    }
                }
            }
        }
    }

    /// The picture as a player shows it, 8-bit red, green, and blue for each pixel, row by
    /// row: the border as it is, and inside it the picture moved by the fine scroll.
    public func rgb() -> [UInt8] {
        let (w, h, tw, th) = (Self.width, Self.height, Self.tileWidth, Self.tileHeight)
        let palette = colors.map { color -> (UInt8, UInt8, UInt8) in
            (UInt8((color >> 8) & 0x0F) * 17, UInt8((color >> 4) & 0x0F) * 17, UInt8(color & 0x0F) * 17)
        }
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let inside = x >= tw && x < w - tw && y >= th && y < h - th
                let source = inside ? (y + verticalOffset) * w + x + horizontalOffset : y * w + x
                let (r, g, b) = palette[Int(pixels[min(source, pixels.count - 1)])]
                out[(y * w + x) * 3] = r
                out[(y * w + x) * 3 + 1] = g
                out[(y * w + x) * 3 + 2] = b
            }
        }
        return out
    }
}
