import UIKit

/// Turns whatever the photo library hands back (HEIC, PNG, full-resolution
/// JPEG, ...) into an upload-sized JPEG: long edge capped at
/// `maxLongEdge` pixels (never upscaled), re-encoded at `jpegQuality`.
///
/// Pure and `nonisolated` (this target defaults to MainActor isolation) so
/// it can run off the main actor — `AddPhotoViewModel.submit()` calls it from
/// a detached task, since decoding and redrawing a 12MP+ photo takes long
/// enough to visibly stall the UI — and so it is unit-testable without a
/// view. `UIGraphicsImageRenderer` is documented as safe to use off the main
/// thread.
nonisolated enum PhotoImageEncoder {
    static let maxLongEdge: CGFloat = 1600
    static let jpegQuality: CGFloat = 0.8

    /// `nil` when `data` isn't a decodable image.
    ///
    /// Drawing through `UIImage.draw(in:)` (rather than handing the
    /// `CGImage` straight to an encoder) bakes the EXIF orientation into the
    /// pixels, so a portrait iPhone photo stays upright everywhere it's
    /// shown — the re-encoded JPEG carries no orientation tag.
    static func encode(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let target = targetSize(for: pixelSize)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.jpegData(withCompressionQuality: jpegQuality) { context in
            // JPEG has no alpha: fill first so a transparent PNG/screenshot
            // comes out on white instead of black.
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Scales `size` down so its long edge is at most `maxLongEdge`,
    /// preserving aspect ratio and rounding to whole pixels. Sizes already
    /// within the limit come back unchanged.
    static func targetSize(for size: CGSize) -> CGSize {
        let longEdge = max(size.width, size.height)
        guard longEdge > maxLongEdge else { return size }
        let ratio = maxLongEdge / longEdge
        return CGSize(
            width: max(1, (size.width * ratio).rounded()),
            height: max(1, (size.height * ratio).rounded())
        )
    }
}
