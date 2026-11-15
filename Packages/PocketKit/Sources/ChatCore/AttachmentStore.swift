import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image attachments on disk: `Application Support/Attachments/<uuid>.jpg`, downscaled on the
/// way in so a 48 MP photo does not cost 48 MP of memory every time a chat is shown.
public struct AttachmentStore: Sendable {
    /// Longest side of a stored image. Vision models resize further themselves.
    public static let maxPixelSize = 1536

    public enum AttachmentError: LocalizedError {
        case unreadableImage

        public var errorDescription: String? { "This image could not be read." }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func applicationSupport() throws -> AttachmentStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return AttachmentStore(directory: base.appending(path: "Attachments", directoryHint: .isDirectory))
    }

    public func url(for name: String) -> URL {
        directory.appending(path: name)
    }

    /// Downscales and stores image data (any format ImageIO reads). Returns the file name.
    public func save(imageData: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,  // honour EXIF orientation
                    kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelSize,
                ] as CFDictionary)
        else { throw AttachmentError.unreadableImage }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".jpg"
        let url = url(for: name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw AttachmentError.unreadableImage }
        // No metadata is copied: location and camera details stay out of the stored file.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AttachmentError.unreadableImage }
        return name
    }

    /// Deletes files; missing files are ignored.
    public func delete(_ names: [String]) {
        for name in names where !name.isEmpty && !name.contains("/") {
            try? FileManager.default.removeItem(at: url(for: name))
        }
    }
}
