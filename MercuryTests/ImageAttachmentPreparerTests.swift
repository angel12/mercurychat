import ChatCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

// NOTE: no `import Mercury` — the app has no module; this test bundle
// compiles Mercury/ImageAttachmentPreparer.swift directly (project.yml).

/// Generate a solid-color image of the given pixel size, encoded as `type`.
private func imageData(width: Int, height: Int, type: UTType) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func pixelSize(of data: Data) -> (Int, Int) {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    return (props[kCGImagePropertyPixelWidth] as! Int, props[kCGImagePropertyPixelHeight] as! Int)
}

@Suite("ImageAttachmentPreparer")
struct ImageAttachmentPreparerTests {
    @Test func smallJPEGPassesThroughUnchanged() throws {
        let data = imageData(width: 100, height: 80, type: .jpeg)
        let prepared = try ImageAttachmentPreparer.prepare(data: data, suggestedName: "small.jpg")
        #expect(prepared.data == data)
        #expect(prepared.filename == "small.jpg")
        #expect(prepared.kind == .image)
    }

    @Test func oversizedImageIsDownscaledToMaxPixelSize() throws {
        let data = imageData(width: 4096, height: 2048, type: .png)
        let prepared = try ImageAttachmentPreparer.prepare(data: data, suggestedName: "big.png")
        let (width, height) = pixelSize(of: prepared.data)
        #expect(width == ImageAttachmentPreparer.maxPixelSize)
        #expect(height == ImageAttachmentPreparer.maxPixelSize / 2)
        #expect(prepared.filename == "big.jpg")  // transcoded → .jpg
    }

    @Test func heicIsTranscodedToJPEG() throws {
        // Not every Mac build environment ships a HEIC *encoder*; skip the
        // fixture (not the product code) when one isn't available.
        guard
            CGImageDestinationCreateWithData(
                NSMutableData(), UTType.heic.identifier as CFString, 1, nil) != nil
        else { return }
        let data = imageData(width: 200, height: 200, type: .heic)
        let prepared = try ImageAttachmentPreparer.prepare(data: data, suggestedName: "shot.heic")
        let source = CGImageSourceCreateWithData(prepared.data as CFData, nil)!
        #expect(CGImageSourceGetType(source) == UTType.jpeg.identifier as CFString)
        #expect(prepared.filename == "shot.jpg")
    }

    @Test func nonImageDataIsRejected() {
        #expect(throws: ImagePreparationError.notAnImage) {
            _ = try ImageAttachmentPreparer.prepare(
                data: Data("not an image".utf8), suggestedName: nil)
        }
    }
}
