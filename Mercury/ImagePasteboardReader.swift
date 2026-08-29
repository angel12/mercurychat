#if os(macOS)
    import AppKit
    import Foundation
    import UniformTypeIdentifiers

    /// Pure pasteboard → image payload CLASSIFICATION, split out of the ⌘V key
    /// handler (in ChatView.swift) so the ordering rules stay readable and
    /// testable without pulling SwiftUI into the test target.
    ///
    /// Deliberately does no disk I/O. `NSPasteboard` must be read on the main
    /// thread and `ComposerAttachments.pasteImages` is MainActor-isolated, so
    /// reading a pasted file HERE put an unbounded, uncapped whole-file read
    /// on the MainActor — freezing the composer for the length of a large
    /// paste and skipping the 60 MB source check that every other input path
    /// gets. Classification is cheap and stays; the read is handed to
    /// `ComposerAttachments.addReserved(contentsOf:)` like the drop path's.
    enum ImagePasteboardReader {
        struct Contents: Equatable {
            /// Image FILES on the pasteboard (Finder ⌘C). Filenames survive,
            /// and the bytes are read off the MainActor, under the cap.
            var imageURLs: [URL] = []
            /// Screenshot / "copy image": raw bytes with no backing file.
            /// Already resident in the pasteboard, so there is nothing to
            /// move off the MainActor. Mutually exclusive with `imageURLs`.
            var rawImage: Data?

            var isEmpty: Bool { imageURLs.isEmpty && rawImage == nil }
        }

        static func read(_ pasteboard: NSPasteboard) -> Contents {
            var contents = Contents()

            // 1. Finder ⌘C: image-conforming file URLs. Filenames survive.
            let imageURLs =
                pasteboard.readObjects(
                    forClasses: [NSURL.self],
                    options: [
                        .urlReadingContentsConformToTypes: [UTType.image.identifier]
                    ]) as? [URL] ?? []
            contents.imageURLs = imageURLs

            // Any file URL at all, unfiltered — used below to tell "copied a
            // non-image file" apart from "copied a screenshot / image bytes
            // with no backing file."
            let anyFileURLs =
                pasteboard.readObjects(forClasses: [NSURL.self], options: [:]) as? [URL] ?? []

            // 2. Screenshot / "copy image" case: raw bytes, no filename. Only
            //    consulted when the pasteboard carried NO file URL at all —
            //    Finder puts the copied file's ICON on the pasteboard next to
            //    the URL (even for a PDF, .txt, or folder), and attaching a
            //    64 px icon in place of the non-image file the user copied is
            //    worse than doing nothing and letting ⌘V fall through.
            if imageURLs.isEmpty, anyFileURLs.isEmpty,
                let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
            {
                contents.rawImage = data
            }
            return contents
        }
    }
#endif
