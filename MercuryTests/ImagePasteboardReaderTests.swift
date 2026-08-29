#if os(macOS)
    import AppKit
    import CoreGraphics
    import Foundation
    import ImageIO
    import Testing
    import UniformTypeIdentifiers

    // NOTE: no `import Mercury` — the app has no module; this test bundle
    // compiles Mercury/ImagePasteboardReader.swift directly (project.yml).

    /// Generate a solid-color PNG of the given pixel size.
    private func pngData(width: Int = 10, height: Int = 10) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A fresh private pasteboard per test, so tests never fight over
    /// `NSPasteboard.general` or each other. Headless-safe on macOS.
    private func makeTestPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    @Suite("ImagePasteboardReader")
    struct ImagePasteboardReaderTests {
        @Test func imageFileURLIsReadWithItsFilename() throws {
            let pasteboard = makeTestPasteboard()
            let data = pngData()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("png")
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            pasteboard.writeObjects([url as NSURL])

            let contents = ImagePasteboardReader.read(pasteboard)
            #expect(contents.images.count == 1)
            #expect(contents.images.first?.data == data)
            #expect(contents.images.first?.name == url.lastPathComponent)
            #expect(contents.unreadableNames.isEmpty)
        }

        @Test func rawImageDataWithNoFileURLIsReadWithNoName() {
            let pasteboard = makeTestPasteboard()
            let data = pngData()
            pasteboard.setData(data, forType: .png)

            let contents = ImagePasteboardReader.read(pasteboard)
            #expect(contents.images.count == 1)
            #expect(contents.images.first?.data == data)
            #expect(contents.images.first?.name == nil)
            #expect(contents.unreadableNames.isEmpty)
        }

        /// Regression pin for the review finding: copying a non-image file in
        /// Finder (a .txt here) puts that file's URL on the pasteboard *and*
        /// its Finder icon as raw PNG/TIFF data. Before the fix, the reader's
        /// raw-data fallback only checked whether any *image-conforming* URL
        /// was present — which is empty here — so it attached the icon
        /// bytes. The fix must see the non-image file URL and refuse to fall
        /// back to the (icon) bytes at all.
        @Test func nonImageFileURLWithStaleIconDataYieldsNoAttachment() throws {
            let pasteboard = makeTestPasteboard()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("txt")
            try Data("not an image".utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            pasteboard.writeObjects([url as NSURL])
            // Simulate Finder placing the file's icon alongside the URL.
            pasteboard.setData(pngData(), forType: .png)

            let contents = ImagePasteboardReader.read(pasteboard)
            #expect(contents.images.isEmpty)
            #expect(contents.unreadableNames.isEmpty)
        }

        @Test func emptyPasteboardYieldsNoAttachment() {
            let pasteboard = makeTestPasteboard()

            let contents = ImagePasteboardReader.read(pasteboard)
            #expect(contents.images.isEmpty)
            #expect(contents.unreadableNames.isEmpty)
        }
    }
#endif
