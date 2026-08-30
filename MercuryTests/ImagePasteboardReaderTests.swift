#if os(macOS)
    import AppKit
    import ChatCore
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
        /// (`pasteAttachments` is MainActor-isolated), which is exactly
        /// what the off-main `addReserved(contentsOf:)` path exists to avoid.
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

        @Test func nonImageFileURLsAreClassifiedAsFiles() throws {
            let pasteboard = makeTestPasteboard()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("doc-\(UUID().uuidString)")
                .appendingPathExtension("txt")
            try Data("x".utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            pasteboard.writeObjects([url as NSURL])

            let contents = ImagePasteboardReader.read(pasteboard)
            #expect(contents.fileURLs == [url])
            #expect(contents.imageURLs.isEmpty)
            #expect(contents.rawImage == nil)
            #expect(!contents.isEmpty)
        }

        /// One URL lands in exactly one bucket, and both buckets keep the
        /// pasteboard's own order.
        @Test func mixedCopyKeepsImagesAndFilesSeparate() throws {
            let pasteboard = makeTestPasteboard()
            let dir = FileManager.default.temporaryDirectory
            let png = dir.appendingPathComponent("p-\(UUID().uuidString).png")
            let txt = dir.appendingPathComponent("t-\(UUID().uuidString).txt")
            try pngData().write(to: png)
            try Data("x".utf8).write(to: txt)
            defer {
                try? FileManager.default.removeItem(at: png)
                try? FileManager.default.removeItem(at: txt)
            }

            pasteboard.writeObjects([png as NSURL, txt as NSURL])

            let contents = ImagePasteboardReader.read(pasteboard)
            #expect(contents.imageURLs == [png])
            #expect(contents.fileURLs == [txt])
            #expect(contents.rawImage == nil)
        }

        /// Regression pin for the review finding, now inverted by task 7:
        /// copying a non-image file in Finder (a .txt here) puts that file's
        /// URL on the pasteboard *and* its Finder icon as raw PNG/TIFF data.
        /// The file itself now attaches — but as a FILE. The icon bytes must
        /// still never be mistaken for the image the user copied.
        @Test func nonImageFileURLWithStaleIconDataAttachesTheFileNotTheIcon() throws {
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
            #expect(contents.fileURLs == [url])
            #expect(contents.imageURLs.isEmpty)
            #expect(contents.rawImage == nil)
        }

        /// Copying a LINK in a browser puts an `NSURL` on the pasteboard too,
        /// but it addresses no file. Classifying it would swallow the ⌘V and
        /// stage an unreadable attachment instead of pasting the link text.
        @Test func webURLIsNotClassifiedAsAFile() {
            let pasteboard = makeTestPasteboard()
            pasteboard.writeObjects([NSURL(string: "https://example.com/page")!])
            pasteboard.setString("https://example.com/page", forType: .string)

            let contents = ImagePasteboardReader.read(pasteboard)
            #expect(contents.fileURLs.isEmpty)
            #expect(contents.imageURLs.isEmpty)
            #expect(contents.isEmpty)
        }

        /// A browser's "Copy Image" puts the bytes on the pasteboard AND, very
        /// often, the image's source `https:` URL as a sidecar. Only FILE URLs
        /// signal "the user copied a file, whose icon these bytes are" — a web
        /// URL says the opposite, so the bytes are the image to attach.
        @Test func rawImageWithAWebURLSidecarIsStillAttached() {
            let pasteboard = makeTestPasteboard()
            pasteboard.writeObjects([NSURL(string: "https://example.com/cat.png")!])
            pasteboard.setData(pngData(), forType: .png)

            let contents = ImagePasteboardReader.read(pasteboard)
            #expect(contents.rawImage != nil)
            #expect(contents.fileURLs.isEmpty)
            #expect(contents.imageURLs.isEmpty)
        }

        @Test func emptyPasteboardYieldsNoAttachment() {
            let pasteboard = makeTestPasteboard()

            let contents = ImagePasteboardReader.read(pasteboard)
            #expect(contents.isEmpty)
        }
    }

    /// `pasteAttachments` end-to-end: classification on the MainActor, the
    /// read and the cap off it.
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
            #expect(composer.pasteAttachments(from: pasteboard))
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
            #expect(composer.pasteAttachments(from: pasteboard))
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
            #expect(composer.pasteAttachments(from: pasteboard))
            await settle(composer)

            #expect(composer.items.count == 1)
            #expect(composer.error == nil)
        }

        /// The behavior change of this task: a Finder ⌘C of a .txt used to
        /// fall through and insert the file's PATH into the field.
        @Test func pastedNonImageFileIsStagedAsAFile() async throws {
            let pasteboard = makeTestPasteboard()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("paste-file-\(UUID().uuidString)")
                .appendingPathExtension("txt")
            try Data("hello".utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            pasteboard.writeObjects([url as NSURL])

            let composer = ComposerAttachments()
            #expect(composer.pasteAttachments(from: pasteboard))
            #expect(composer.isBusyPreparing)
            await settle(composer)

            #expect(composer.items.count == 1)
            #expect(composer.items.first?.filename == url.lastPathComponent)
            #expect(composer.items.first?.kind == .file)
            // Raw bytes, no transcode and no thumbnail.
            #expect(composer.items.first?.data == Data("hello".utf8))
            #expect(composer.error == nil)
        }

        /// One batch, one reservation over both buckets, staged in
        /// pasteboard order (images first, then files).
        @Test func mixedPasteStagesImagesAndFilesInOneBatch() async throws {
            let pasteboard = makeTestPasteboard()
            let dir = FileManager.default.temporaryDirectory
            let png = dir.appendingPathComponent("paste-mix-\(UUID().uuidString).png")
            let txt = dir.appendingPathComponent("paste-mix-\(UUID().uuidString).txt")
            try pngData().write(to: png)
            try Data("x".utf8).write(to: txt)
            defer {
                try? FileManager.default.removeItem(at: png)
                try? FileManager.default.removeItem(at: txt)
            }

            pasteboard.writeObjects([png as NSURL, txt as NSURL])

            let composer = ComposerAttachments()
            #expect(composer.pasteAttachments(from: pasteboard))
            // Both slots reserved before the first read is scheduled.
            #expect(composer.preparing == 2)
            await settle(composer)

            #expect(
                composer.items.map(\.filename)
                    == [png.lastPathComponent, txt.lastPathComponent])
            #expect(composer.items.map(\.kind) == [.image, .file])
            #expect(composer.error == nil)
        }

        /// The cap is one budget across both buckets: with 4 staged, a
        /// 2-URL paste gets one slot and says so.
        @Test func mixedPasteAtCapReservesOnceAcrossBothBuckets() async throws {
            let pasteboard = makeTestPasteboard()
            let dir = FileManager.default.temporaryDirectory
            let png = dir.appendingPathComponent("cap-\(UUID().uuidString).png")
            let txt = dir.appendingPathComponent("cap-\(UUID().uuidString).txt")
            try pngData().write(to: png)
            try Data("x".utf8).write(to: txt)
            defer {
                try? FileManager.default.removeItem(at: png)
                try? FileManager.default.removeItem(at: txt)
            }

            pasteboard.writeObjects([png as NSURL, txt as NSURL])

            let composer = ComposerAttachments()
            for index in 0..<4 {
                composer.items.append(
                    PendingAttachment(
                        filename: "existing-\(index).png", data: Data("x".utf8)))
            }

            #expect(composer.pasteAttachments(from: pasteboard))
            #expect(composer.preparing == 1)
            await settle(composer)

            #expect(composer.items.count == 5)
            #expect(composer.items.last?.filename == png.lastPathComponent)
            #expect(composer.error == "Up to 5 attachments per message.")
        }

        /// A file the reader classified but the composer cannot read still
        /// counts as handled: falling through would insert its path.
        @Test func unreadablePastedFileIsHandledAndReportsTheFailure() async {
            let pasteboard = makeTestPasteboard()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("gone-\(UUID().uuidString)")
                .appendingPathExtension("txt")
            // Never created: the URL is on the pasteboard, the file is not
            // on disk.
            pasteboard.writeObjects([url as NSURL])

            let composer = ComposerAttachments()
            #expect(composer.pasteAttachments(from: pasteboard))
            await settle(composer)

            #expect(composer.items.isEmpty)
            #expect(composer.error == "Couldn't read \(url.lastPathComponent).")
        }

        /// A copied browser link is text, not an attachment — the field
        /// editor must still get it.
        @Test func webURLPasteIsNotHandled() {
            let pasteboard = makeTestPasteboard()
            pasteboard.writeObjects([NSURL(string: "https://example.com/page")!])
            pasteboard.setString("https://example.com/page", forType: .string)

            let composer = ComposerAttachments()
            #expect(composer.pasteAttachments(from: pasteboard) == false)
            #expect(composer.preparing == 0)
        }

        @Test func plainTextPasteIsNotHandledAndStartsNoBatch() {
            let pasteboard = makeTestPasteboard()
            pasteboard.setString("just text", forType: .string)

            let composer = ComposerAttachments()
            composer.error = "Couldn't load photo."
            // `.ignored` hands the paste to the field editor — and must not
            // wipe a visible attachment failure the user never acted on.
            #expect(composer.pasteAttachments(from: pasteboard) == false)
            #expect(composer.error == "Couldn't load photo.")
            #expect(composer.preparing == 0)
        }
    }
#endif
