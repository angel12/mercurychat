import ChatCore
import Foundation
import Observation
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#endif

/// Staged attachments plus every way they get added. Lifted out of
/// `ComposerView` into a shared object because the drop target spans the
/// whole chat surface (#3): `ChatContentView` owns the instance, the composer
/// renders and sends it. Kept out of ChatView.swift so MercuryTests can
/// compile the state machine without SwiftUI.
@MainActor
@Observable
final class ComposerAttachments {
    var items: [PendingAttachment] = []
    var error: String?

    /// In-flight preparations (read + decode/resize/encode), counted on the
    /// MainActor from BEFORE the detached work is spawned until every exit
    /// path of that work. Preparation is asynchronous, so without this the
    /// composer would happily send the caption on its own and let the image
    /// land in the tray for the NEXT message: `> 0` holds Send and shrinks
    /// the picker's selection budget.
    private(set) var preparing = 0

    /// One cap for every input path (picker, paste, drop, file importer). The
    /// photo picker's `maxSelectionCount` is derived from it and the current
    /// tray count, so the two can't drift.
    static let maxAttachments = 5

    /// Ceiling on bytes pulled off disk before preparation. Anything larger
    /// can't survive `ImageAttachmentPreparer`'s 20 MB encoded cap anyway, so
    /// reject it from the file's metadata rather than reading it into memory.
    static let maxSourceFileBytes = 60 * 1024 * 1024

    /// Slots a NEW attachment could still claim: the cap minus what is
    /// staged AND minus what is already being prepared. The photo picker's
    /// budget comes from here, so a picker opened mid-preparation can't hand
    /// back more items than the tray will accept.
    var availableSlots: Int {
        max(0, Self.maxAttachments - items.count - preparing)
    }

    /// True while any input path is still turning bytes into an attachment.
    /// The composer holds Send on this.
    var isBusyPreparing: Bool { preparing > 0 }

    func clear() {
        items = []
        error = nil
    }

    /// Start of one user-initiated batch (a drop, one file-importer result,
    /// one picker selection, one paste). The error line is batch-scoped: it
    /// is cleared HERE and never by an individual success, so a failure
    /// anywhere in a batch stays visible until the user acts again.
    func beginBatch() {
        error = nil
    }

    /// Reserve a slot for one preparation, or refuse with the cap error.
    /// Check and reservation happen in one MainActor step so concurrent
    /// preparations can't all clear the same stale check.
    @discardableResult
    func beginPreparation() -> Bool {
        guard availableSlots > 0 else {
            error = "Up to \(Self.maxAttachments) images per message."
            return false
        }
        preparing += 1
        return true
    }

    /// Release a reservation. Every exit path of a preparation runs this
    /// (via `defer`), so a failure can never strand the Send gate.
    func endPreparation() {
        if preparing > 0 { preparing -= 1 }
    }

    /// Commit a prepared attachment, re-checking the cap at append time
    /// (the reservation is released by the caller's `defer`, and the tray
    /// may have filled while this one was being encoded). Returns false —
    /// with the cap error set — when there is no room left.
    @discardableResult
    func append(_ attachment: PendingAttachment) -> Bool {
        guard items.count < Self.maxAttachments else {
            error = "Up to \(Self.maxAttachments) images per message."
            return false
        }
        items.append(attachment)
        return true
    }

    /// `ImageAttachmentPreparer.prepare` is two ImageIO decode/resize/encode
    /// passes — far too much to run on the MainActor, where it stalls the
    /// composer for the whole of a large image (#2). Only the pure work
    /// leaves; the cap, the counter and the error line stay here.
    func add(data: Data, name: String?) async {
        guard beginPreparation() else { return }
        defer { endPreparation() }
        await prepareAndAppend(data: data, name: name)
    }

    /// Reads a picked/dropped file URL under its security scope — sandboxed
    /// builds only get read access for the duration of that scope.
    func addContents(of url: URL) async {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size > Self.maxSourceFileBytes
        {
            error = "Image is too large to send (60 MB max)."
            return
        }
        guard beginPreparation() else { return }
        defer { endPreparation() }
        // Whole-file read off the MainActor too: a big image on a slow volume
        // blocks just as long as the encode did.
        guard let data = await Task.detached(operation: { Self.readSecurityScoped(url) }).value
        else {
            error = "Couldn't read \(url.lastPathComponent)."
            return
        }
        await prepareAndAppend(data: data, name: url.lastPathComponent)
    }

    /// Encode + append for a preparation whose slot is already reserved.
    private func prepareAndAppend(data: Data, name: String?) async {
        do {
            let prepared = try await Task.detached {
                try ImageAttachmentPreparer.prepare(data: data, suggestedName: name)
            }.value
            append(prepared)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Pure file read — `nonisolated` so callers off the main actor can use it.
    nonisolated static func readSecurityScoped(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
    }

    /// Shared by drop and `onPasteCommand`: prefer the file URL representation
    /// so the filename survives, and fall back to raw image bytes. One call =
    /// one batch.
    func loadProviders(_ providers: [NSItemProvider]) {
        beginBatch()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await self.addContents(of: url) }
                }
            } else {
                _ = provider.loadDataRepresentation(for: .image) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in await self.add(data: data, name: nil) }
                }
            }
        }
    }

    #if os(macOS)
        /// ⌘V handler (#4). Returns true only when at least one attachment was
        /// staged, so a plain text paste is never swallowed.
        @discardableResult
        func pasteImages(from pasteboard: NSPasteboard = .general) -> Bool {
            let contents = ImagePasteboardReader.read(pasteboard)
            beginBatch()
            // Preparation is async now; one task awaiting them in order keeps
            // a multi-image paste staged in pasteboard order.
            if !contents.images.isEmpty {
                Task { @MainActor in
                    for image in contents.images {
                        await add(data: image.data, name: image.name)
                    }
                }
            }
            if contents.images.isEmpty, let name = contents.unreadableNames.first {
                error = "Couldn't read \(name)."
                // Still "handled": the pasteboard held an image file, so
                // falling through to a text paste would insert its path.
                return true
            }
            return !contents.images.isEmpty
        }
    #endif
}
