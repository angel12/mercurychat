import ChatCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImagePreparationError: LocalizedError, Equatable {
    case notAnImage
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .notAnImage: return "That doesn't look like an image."
        case .tooLarge: return "Image is too large to send (20 MB max after compression)."
        }
    }
}

/// Normalizes picked/pasted/dropped image bytes into what the wire should
/// carry: web-friendly format (JPEG/PNG), ≤ 2048 px longest side, ≤ 20 MB.
/// The server rejects `image.attach_bytes` payloads over 25 MB and base64
/// inflates ×1.37, so 20 MB encoded keeps the frame comfortably legal.
enum ImageAttachmentPreparer {
    static let maxPixelSize = 2048
    static let maxEncodedBytes = 20 * 1024 * 1024

    static func prepare(data: Data, suggestedName: String?) throws -> PendingAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else { throw ImagePreparationError.notAnImage }

        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let type = CGImageSourceGetType(source) as String?
        let isWebFriendly =
            type == UTType.jpeg.identifier || type == UTType.png.identifier

        if isWebFriendly, max(width, height) <= maxPixelSize, data.count <= maxEncodedBytes {
            // Default name must match the actual pass-through format.
            let fallback = type == UTType.png.identifier ? "image.png" : "image.jpg"
            return PendingAttachment(
                filename: suggestedName ?? fallback, data: data,
                thumbnail: thumbnailJPEG(from: source))
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // bake in EXIF rotation
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard
            let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw ImagePreparationError.notAnImage }

        let encoded = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                encoded, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ImagePreparationError.notAnImage }
        CGImageDestinationAddImage(
            destination, scaled,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImagePreparationError.notAnImage
        }
        guard encoded.count <= maxEncodedBytes else { throw ImagePreparationError.tooLarge }

        let base = (suggestedName as NSString?)?.deletingPathExtension ?? "image"
        return PendingAttachment(
            filename: "\(base).jpg", data: encoded as Data,
            thumbnail: thumbnailJPEG(from: source))
    }

    /// ≤512 px JPEG for tray/echo thumbnails so the transcript never holds
    /// the full wire bytes. Nil on failure — callers fall back to `data`.
    private static func thumbnailJPEG(from source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ]
        guard
            let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let encoded = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                encoded, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, small,
            [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }
}
