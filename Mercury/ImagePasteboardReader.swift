#if os(macOS)
    import AppKit
    import Foundation
    import UniformTypeIdentifiers

    /// Pure pasteboard → attachment payload CLASSIFICATION, split out of the
    /// ⌘V key handler (in ChatView.swift) so the ordering rules stay readable
    /// and testable without pulling SwiftUI into the test target.
    ///
    /// Deliberately does no disk I/O. `NSPasteboard` must be read on the main
    /// thread and `ComposerAttachments.pasteAttachments` is MainActor-isolated,
    /// so reading a pasted file HERE put an unbounded, uncapped whole-file read
    /// on the MainActor — freezing the composer for the length of a large
    /// paste and skipping the source-size check that every other input path
    /// gets. Classification is cheap and stays; the read is handed to
    /// `ComposerAttachments.addReserved(contentsOf:)` like the drop path's.
    enum ImagePasteboardReader {
        struct Contents: Equatable {
            /// Image FILES on the pasteboard (Finder ⌘C). Filenames survive,
            /// and the bytes are read off the MainActor, under the cap.
            var imageURLs: [URL] = []
            /// Every OTHER file on the pasteboard — a PDF, a .txt, anything.
            /// These attach as well now that `addReserved(contentsOf:)`
            /// stages any kind; before, a copied non-image file fell through
            /// to a text paste that inserted its PATH. Disjoint from
            /// `imageURLs`: one URL lands in exactly one of the two.
            var fileURLs: [URL] = []
            /// Screenshot / "copy image": raw bytes with no backing file.
            /// Already resident in the pasteboard, so there is nothing to
            /// move off the MainActor. Mutually exclusive with the URL lists.
            var rawImage: Data?

            var isEmpty: Bool { imageURLs.isEmpty && fileURLs.isEmpty && rawImage == nil }
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

            // Every URL on the pasteboard, unfiltered — the source of the
            // non-image files below, and the signal that tells "copied a
            // file" apart from "copied a screenshot / image bytes with no
            // backing file."
            let anyFileURLs =
                pasteboard.readObjects(forClasses: [NSURL.self], options: [:]) as? [URL] ?? []

            // 2. Every other FILE: PDFs, .txt, anything with bytes on disk.
            //    `addReserved(contentsOf:)` classifies and caps by kind, so
            //    the only job here is subtracting the image files already
            //    claimed above — one URL must never be staged twice.
            //
            //    Non-file URLs are excluded on purpose: copying a LINK in a
            //    browser also puts an `NSURL` on the pasteboard, and treating
            //    that as an attachment would swallow the ⌘V and stage an
            //    unreadable item instead of pasting the link text.
            let claimed = Set(imageURLs.map(\.standardizedFileURL))
            contents.fileURLs = anyFileURLs.filter {
                $0.isFileURL && !claimed.contains($0.standardizedFileURL)
            }

            // 3. Screenshot / "copy image" case: raw bytes, no filename. Only
            //    consulted when the pasteboard carried NO file URL at all —
            //    Finder puts the copied file's ICON on the pasteboard next to
            //    the URL (even for a PDF, .txt, or folder), and attaching a
            //    64 px icon in place of the file the user copied would be
            //    wrong — that file is staged from its URL above.
            if imageURLs.isEmpty, anyFileURLs.isEmpty,
                let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
            {
                contents.rawImage = data
            }
            return contents
        }
    }
#endif
