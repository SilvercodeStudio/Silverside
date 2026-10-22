import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A cover image ready to embed in audio files: at most `maximumPixels` on its long side,
/// so each file stays small. The folder's cover.jpg keeps the full size.
public struct EmbeddedCover: Equatable, Sendable {
    public var image: CoverImage
    public var width: Int
    public var height: Int

    /// The long side of an embedded cover, as the user's library has it (1000 × 1000).
    public static let maximumPixels = 1000

    /// Makes an embeddable cover from an image. An image that is already a JPEG or PNG
    /// within the size is kept as it is; a larger one becomes a JPEG at the size.
    public init(_ source: CoverImage, maximumPixels: Int = maximumPixels) throws {
        guard let imageSource = CGImageSourceCreateWithData(source.data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw CoverArtError.unknownFormat }
        if max(width, height) <= maximumPixels && source.fileExtension != nil {
            (image, self.width, self.height) = (source, width, height)
            return
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw CoverArtError.unknownFormat
        }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CoverArtError.unknownFormat }
        CGImageDestinationAddImage(
            destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CoverArtError.unknownFormat }
        (image, self.width, self.height) = (CoverImage(data: output as Data), thumbnail.width, thumbnail.height)
    }
}
