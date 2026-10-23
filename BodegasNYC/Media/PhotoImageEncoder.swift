import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Turns whatever the photo library hands back (HEIC, PNG, full-resolution
/// JPEG, ...) into an upload-sized JPEG: long edge capped at `maxLongEdge`
/// pixels (never upscaled), EXIF orientation baked into the pixels,
/// transparency flattened onto white, re-encoded at `jpegQuality`. Also makes
/// the upload sheet's row thumbnail from the same source.
///
/// ImageIO, not `UIImage(data:)` (#107 eng C1): `CGImageSourceCreateThumbnailAtIndex`
/// decodes straight to the target size, so a 48MP ProRAW pick never sits in
/// memory at full size, and ten picks prepared one after another stay
/// bounded. The original `Data` can be dropped as soon as this returns.
///
/// Pure and `nonisolated` (this target defaults to MainActor isolation) so
/// it runs off the main actor (`AddPhotoViewModel.loadPickedPhotos()` calls
/// it from a detached task) and is unit-testable without a view.
nonisolated enum PhotoImageEncoder {
    static let maxLongEdge: CGFloat = 1600
    static let jpegQuality: CGFloat = 0.8
    /// A row thumbnail's long edge in pixels (64pt at 3x is 192).
    static let thumbnailLongEdge: CGFloat = 256

    /// A picked photo ready to upload: the JPEG to send and a small preview.
    struct Prepared: Sendable {
        let jpeg: Data
        let thumbnail: UIImage
    }

    /// `nil` when `data` isn't a decodable image.
    static func encode(_ data: Data) -> Data? {
        guard let source = makeSource(data) else { return nil }
        return jpeg(from: source)
    }

    /// The upload JPEG plus a thumbnail of at most `thumbnailLongEdge`
    /// pixels, both from one decode of `data`'s header. `nil` when `data`
    /// isn't a decodable image.
    static func prepare(_ data: Data, thumbnailLongEdge: CGFloat = thumbnailLongEdge) -> Prepared? {
        guard let source = makeSource(data),
              let jpeg = jpeg(from: source),
              let thumbnail = orientedImage(from: source, longEdge: thumbnailLongEdge) else { return nil }
        return Prepared(jpeg: jpeg, thumbnail: UIImage(cgImage: thumbnail))
    }

    /// Scales `size` down so its long edge is at most `maxLongEdge`,
    /// preserving aspect ratio and rounding to whole pixels. Sizes already
    /// within the limit come back unchanged.
    static func targetSize(for size: CGSize, maxLongEdge: CGFloat = maxLongEdge) -> CGSize {
        let longEdge = max(size.width, size.height)
        guard longEdge > maxLongEdge else { return size }
        let ratio = maxLongEdge / longEdge
        return CGSize(
            width: max(1, (size.width * ratio).rounded()),
            height: max(1, (size.height * ratio).rounded())
        )
    }

    // MARK: ImageIO

    private static func makeSource(_ data: Data) -> CGImageSource? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return source
    }

    /// The image's pixel size as displayed (width and height swapped for the
    /// EXIF orientations that rotate by 90 degrees).
    private static func orientedPixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let rotatesQuarterTurn = (5...8).contains(orientation)
        return rotatesQuarterTurn ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// Decodes at most `longEdge` pixels on the long side, upright
    /// (`kCGImageSourceCreateThumbnailWithTransform`), never upscaled.
    private static func orientedImage(from source: CGImageSource, longEdge: CGFloat) -> CGImage? {
        guard let size = orientedPixelSize(of: source) else { return nil }
        let target = targetSize(for: size, maxLongEdge: longEdge)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(target.width, target.height))
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Draws the upright image into an opaque white sRGB bitmap (JPEG has no
    /// alpha: a transparent PNG would otherwise come out on black), then
    /// encodes it. The JPEG carries no orientation tag: the pixels are
    /// already upright.
    private static func jpeg(from source: CGImageSource) -> Data? {
        guard let size = orientedPixelSize(of: source),
              let image = orientedImage(from: source, longEdge: maxLongEdge) else { return nil }
        // ImageIO may land a pixel off the rounded target; draw at the exact
        // target so the output size is predictable.
        let target = targetSize(for: size)
        let width = Int(target.width)
        let height = Int(target.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let flattened = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            flattened,
            [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
