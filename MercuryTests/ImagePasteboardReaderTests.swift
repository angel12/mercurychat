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
        /// The reader CLASSIFIES; it must not touch the disk. Reading here
        /// would put an unbounded, uncapped whole-file read on the MainActor
        /// (`pasteImages` is MainActor-isolated), which is exactly what the
        /// off-main `addReserved(contentsOf:)` path exists to avoid.
        @Test func imageFileURLIsClassifiedWithoutReadingIt() throws {
            let pasteboard = makeTestPasteboard()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("png")
            try pngData().write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            pasteboard.writeObjects([url as NSURL])

            let contents = ImagePasteboardReader.read(pasteboard)
            #expect(contents.imageURLs.count == 1)
            #expect(contents.imageURLs.first?.lastPathComponent == url.lastPathComponent)
            #expect(contents.rawImage == nil)
        }

        @Test func rawImageDataWithNoFileURLIsCarriedAsBytes() {
            let pasteboard = makeTestPasteboard()
            let data = pngData()
            pasteboard.setData(data, forType: .png)

            let contents = ImagePasteboardReader.read(pasteboard)
            // Already in memory (the pasteboard holds them), so there is no
            // disk read to move off the MainActor.
            #expect(contents.rawImage == data)
            #expect(contents.imageURLs.isEmpty)
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
            #expect(contents.imageURLs.isEmpty)
            #expect(contents.rawImage == nil)
            #expect(contents.isEmpty)
        }

        @Test func emptyPasteboardYieldsNoAttachment() {
            let pasteboard = makeTestPasteboard()

            let contents = ImagePasteboardReader.read(pasteboard)
            #expect(contents.isEmpty)
        }
    }

    /// `pasteImages` end-to-end: classification on the MainActor, the read
    /// and the cap off it.
    @MainActor
    @Suite("Paste staging")
    struct PasteStagingTests {
        /// The paste hands its file read to a detached task; wait for the
        /// Send gate to drop rather than guessing at a fixed delay.
        private func settle(_ composer: ComposerAttachments) async {
            for _ in 0..<400 {
                if !composer.isBusyPreparing { return }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            Issue.record("preparation never finished")
        }

        @Test func oversizedPastedFileIsRejectedWithoutBeingRead() async throws {
            let pasteboard = makeTestPasteboard()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("paste-cap-\(UUID().uuidString)")
                .appendingPathExtension("png")
            // Sparse file: over the 60 MB source cap but costs no disk. If the
            // gate did not fire, the read would hand `prepare` 60 MB of zeros
            // and the error would be a DECODE failure instead of this one.
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(ComposerAttachments.maxSourceFileBytes + 1))
            try handle.close()
            defer { try? FileManager.default.removeItem(at: url) }

            pasteboard.writeObjects([url as NSURL])

            let composer = ComposerAttachments()
            // Handled either way: the pasteboard held an image FILE, so
            // falling through to a text paste would insert its path.
            #expect(composer.pasteImages(from: pasteboard))
            await settle(composer)

            #expect(composer.items.isEmpty)
            #expect(composer.error == "Image is too large to send (60 MB max).")
            #expect(composer.preparing == 0)
        }

        @Test func pastedImageFileIsStagedWithItsFilename() async throws {
            let pasteboard = makeTestPasteboard()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("paste-ok-\(UUID().uuidString)")
                .appendingPathExtension("png")
            try pngData().write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            pasteboard.writeObjects([url as NSURL])

            let composer = ComposerAttachments()
            #expect(composer.pasteImages(from: pasteboard))
            // Reserved synchronously, before the read is even scheduled.
            #expect(composer.isBusyPreparing)
            await settle(composer)

            #expect(composer.items.count == 1)
            #expect(composer.items.first?.filename == url.lastPathComponent)
            #expect(composer.error == nil)
        }

        @Test func pastedRawBytesAreStagedWithoutAFilename() async {
            let pasteboard = makeTestPasteboard()
            pasteboard.setData(pngData(), forType: .png)

            let composer = ComposerAttachments()
            #expect(composer.pasteImages(from: pasteboard))
            await settle(composer)

            #expect(composer.items.count == 1)
            #expect(composer.error == nil)
        }

        @Test func plainTextPasteIsNotHandledAndStartsNoBatch() {
            let pasteboard = makeTestPasteboard()
            pasteboard.setString("just text", forType: .string)

            let composer = ComposerAttachments()
            composer.error = "Couldn't load photo."
            // `.ignored` hands the paste to the field editor — and must not
            // wipe a visible attachment failure the user never acted on.
            #expect(composer.pasteImages(from: pasteboard) == false)
            #expect(composer.error == "Couldn't load photo.")
            #expect(composer.preparing == 0)
        }
    }
#endif
