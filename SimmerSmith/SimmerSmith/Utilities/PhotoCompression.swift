import UIKit

/// Resize + JPEG-compress a `UIImage` for upload to the backend.
/// Used by every photo-upload flow (cook-check vision, memory log
/// photos, recipe-image manual override) so all client uploads
/// share the same 2048px / JPEG 0.8 ceiling. Throws if either the
/// resize or JPEG encode step fails.
enum PhotoCompressionError: LocalizedError {
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .compressionFailed:
            return "Could not compress the photo for upload."
        }
    }
}

/// Resize the image so its longest side ≤ `maxSide` (no-op if it
/// already fits), then JPEG-encode at `quality`. Returns the bytes
/// ready for HTTP upload.
func compressPhotoForUpload(
    _ image: UIImage,
    maxSide: CGFloat = 2048,
    quality: CGFloat = 0.8
) throws -> Data {
    let resized: UIImage = {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }()
    guard let data = resized.jpegData(compressionQuality: quality) else {
        throw PhotoCompressionError.compressionFailed
    }
    return data
}
