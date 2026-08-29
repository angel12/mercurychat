#if os(macOS)
    import AppKit
    import Foundation
    import UniformTypeIdentifiers

    /// Pure pasteboard → image payload extraction, split out of the ⌘V key
    /// handler (in ChatView.swift) so the ordering rules stay readable and
    /// testable without pulling SwiftUI into the test target.
    enum ImagePasteboardReader {
        struct Contents: Equatable {
            struct Image: Equatable {
                var data: Data
                /// nil ⇒ let the preparer pick a default filename.
                var name: String?
            }
            var images: [Image] = []
            /// Image files that were on the pasteboard but could not be read
            /// (the sandbox grant that drag-and-drop carries does not always
            /// come along with ⌘C/⌘V).
            var unreadableNames: [String] = []
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
            for url in imageURLs {
                if let data = readSecurityScoped(url) {
                    contents.images.append(.init(data: data, name: url.lastPathComponent))
                } else {
                    contents.unreadableNames.append(url.lastPathComponent)
                }
            }

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
                contents.images.append(.init(data: data, name: nil))
            }
            return contents
        }

        /// Reads a file URL under its security scope — sandboxed builds only
        /// get read access for the duration of that scope. Kept local (rather
        /// than shared with `ComposerAttachments.readSecurityScoped`, which
        /// does the same thing) so this file stays self-contained and can be
        /// compiled into MercuryTests on its own.
        private static func readSecurityScoped(_ url: URL) -> Data? {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try? Data(contentsOf: url)
        }
    }
#endif
