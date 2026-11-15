import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A contact sheet of a release's images: each image's thumbnail in a grid, with its number and
/// types under it, so that the user can choose a cover and the Artwork by eye from a box
/// set's dozens of scans (`silverside album --sheet`).
public enum CoverArtSheet {
    public struct Tile: Sendable {
        /// "12  Booklet · Disc 3", under the image.
        public var label: String
        /// A thumbnail (JPEG or PNG); nil draws an empty tile.
        public var image: Data?

        public init(label: String, image: Data?) {
            self.label = label
            self.image = image
        }
    }

    /// The sheet as a JPEG: `columns` tiles a row, each image fitted in a square of `size` points
    /// (at twice that in pixels), with two lines of label under it.
    public static func make(_ tiles: [Tile], columns: Int = 6, size: Int = 220) throws -> Data {
        let scale = 2
        let gap = 16
        let labelHeight = 34
        let columns = max(1, min(columns, tiles.count))
        let rows = (tiles.count + columns - 1) / columns
        let width = (columns * (size + gap) + gap) * scale
        let height = (rows * (size + labelHeight + gap) + gap) * scale
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CoverArtError.unknownFormat }
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.setFillColor(gray: 0.93, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let pageHeight = CGFloat(height / scale)
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        for (index, tile) in tiles.enumerated() {
            let x = CGFloat(gap + (index % columns) * (size + gap))
            // Core Graphics counts up from the bottom; the first row is at the top.
            let top = CGFloat(gap + (index / columns) * (size + labelHeight + gap))
            let square = CGRect(x: x, y: pageHeight - top - CGFloat(size), width: CGFloat(size), height: CGFloat(size))
            context.setFillColor(gray: 0.85, alpha: 1)
            context.fill(square)
            if let data = tile.image, let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            {
                let fit = min(square.width / CGFloat(image.width), square.height / CGFloat(image.height))
                let drawn = CGSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit)
                context.draw(
                    image,
                    in: CGRect(
                        x: square.midX - drawn.width / 2, y: square.midY - drawn.height / 2, width: drawn.width,
                        height: drawn.height))
            }
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
            ]
            let text = NSAttributedString(string: tile.label, attributes: attributes)
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            let path = CGPath(
                rect: CGRect(
                    x: x, y: square.minY - CGFloat(labelHeight), width: CGFloat(size), height: CGFloat(labelHeight) - 3),
                transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), context)
        }
        guard let sheet = context.makeImage() else { throw CoverArtError.unknownFormat }
        return try CoverImage.jpeg(sheet, quality: 0.85).data
    }
}
