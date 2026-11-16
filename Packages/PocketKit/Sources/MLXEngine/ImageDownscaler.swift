import CoreImage
import Foundation
import ImageIO
import MLXLMCommon

/// Shrinks an image before it reaches the vision model. The stored file is left as it is.
enum ImageDownscaler {
    /// The image at `url` with its longest side at most `maxDimension` pixels, upright. Smaller
    /// images are not enlarged. Falls back to the file itself if it cannot be decoded here.
    static func image(at url: URL, maxDimension: Int) -> UserInput.Image {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { return .url(url) }
        return .ciImage(CIImage(cgImage: thumbnail))
    }
}
