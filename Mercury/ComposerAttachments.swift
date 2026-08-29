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

    /// Reserve up to `count` slots for a batch that is about to ACQUIRE
    /// bytes, returning how many were granted (the cap error is set when that
    /// is fewer than asked). Callers reserve BEFORE the first `await` —
    /// acquisition is itself slow (an iCloud photo's `loadTransferable` takes
    /// seconds, an `NSItemProvider` completion is unbounded), and a
    /// reservation taken only once the bytes land leaves exactly the window
    /// the counter exists to close: Send passes, the caption goes out alone,
    /// and the image lands in the next message's tray.
    ///
    /// Check and reservation happen in one MainActor step, so concurrent
    /// batches can't all clear the same stale check.
    @discardableResult
    func reserveSlots(_ count: Int) -> Int {
        let granted = min(max(0, count), availableSlots)
        if granted < count {
            error = "Up to \(Self.maxAttachments) images per message."
        }
        preparing += granted
        return granted
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

    /// Stage bytes the caller has ALREADY reserved a slot for, consuming that
    /// reservation on every exit path.
    ///
    /// `ImageAttachmentPreparer.prepare` is two ImageIO decode/resize/encode
    /// passes — far too much to run on the MainActor, where it stalls the
    /// composer for the whole of a large image (#2). Only the pure work
    /// leaves; the cap, the counter and the error line stay here.
    ///
    /// There is deliberately NO self-reserving variant: every input path
    /// knows its item count synchronously and must reserve before acquiring,
    /// so a method that reserved on entry would only invite the acquisition
    /// window back in.
    func addReserved(data: Data, name: String?) async {
        defer { endPreparation() }
        await prepareAndAppend(data: data, name: name)
    }

    /// Reads a picked/dropped file URL under its security scope — sandboxed
    /// builds only get read access for the duration of that scope, and the
    /// size pre-check needs that access just as much as the read does.
    /// Consumes a reservation the caller already holds.
    func addReserved(contentsOf url: URL) async {
        defer { endPreparation() }
        // Whole-file read off the MainActor too: a big image on a slow volume
        // blocks just as long as the encode did.
        let maxBytes = Self.maxSourceFileBytes
        let outcome = await Task.detached {
            Self.readSecurityScoped(url, maxBytes: maxBytes)
        }.value
        switch outcome {
        case .success(let data):
            await prepareAndAppend(data: data, name: url.lastPathComponent)
        case .failure(.tooLarge):
            error = "Image is too large to send (60 MB max)."
        case .failure(.unreadable):
            error = "Couldn't read \(url.lastPathComponent)."
        }
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

    enum FileReadFailure: Error, Equatable, Sendable {
        case tooLarge
        case unreadable
    }

    /// Pure file read — `nonisolated` so callers off the main actor can use
    /// it. The size stat runs INSIDE the security scope, alongside the read:
    /// outside it, `resourceValues` on a sandboxed picker/drop URL throws and
    /// the 60 MB pre-check silently no-opped, letting the whole file be read
    /// into memory only for `prepare` to reject it.
    nonisolated static func readSecurityScoped(
        _ url: URL, maxBytes: Int
    ) -> Result<Data, FileReadFailure> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size > maxBytes
        {
            // Size-exceeded returns without reading a single byte.
            return .failure(.tooLarge)
        }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        return .success(data)
    }

    /// Shared by drop and `onPasteCommand`: prefer the file URL representation
    /// so the filename survives, and fall back to raw image bytes. One call =
    /// one batch.
    ///
    /// The whole batch is reserved here, synchronously, because a provider's
    /// load completion is unbounded in time — reserving inside the completion
    /// left the drop unaccounted for until its bytes arrived. Each completion
    /// then either hands its reservation to `addReserved` (which consumes it)
    /// or releases it; `NSItemProvider` guarantees the completion fires with
    /// either a value or an error, so exactly one of the two always happens.
    func loadProviders(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        beginBatch()
        let granted = reserveSlots(providers.count)
        guard granted > 0 else { return }
        for provider in providers.prefix(granted) {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    Task { @MainActor in
                        guard let url else { return self.endPreparation() }
                        await self.addReserved(contentsOf: url)
                    }
                }
            } else {
                _ = provider.loadDataRepresentation(for: .image) { data, _ in
                    Task { @MainActor in
                        guard let data else { return self.endPreparation() }
                        await self.addReserved(data: data, name: nil)
                    }
                }
            }
        }
    }

    #if os(macOS)
        /// ⌘V handler (#4). Returns true when the pasteboard held image
        /// content — even at cap or on a read failure, since falling through
        /// to a text paste would insert the file's path — and false for a
        /// plain text paste, which is never swallowed.
        @discardableResult
        func pasteImages(from pasteboard: NSPasteboard = .general) -> Bool {
            let contents = ImagePasteboardReader.read(pasteboard)
            // A plain TEXT ⌘V is not a batch: returning `.ignored` from here
            // hands the paste to the field editor, so clearing the error line
            // on the way out would wipe a visible attachment failure that the
            // user never acted on. Only image content starts a batch.
            guard !contents.isEmpty else { return false }
            beginBatch()
            // Pasted FILES take the same off-main, size-capped read as a drop
            // (#2): the reader classifies on the MainActor and hands the disk
            // hit to `addReserved(contentsOf:)`, which stats against the
            // 60 MB source cap inside the security scope before reading a
            // byte. Reading here instead froze the composer for the length of
            // a large paste and skipped the cap entirely.
            //
            // Slots are reserved up front, like every other batch; one task
            // awaiting them in order keeps a multi-image paste staged in
            // pasteboard order and leaves no gap between items. Unreadable
            // files now surface their "Couldn't read …" error from that same
            // path rather than being detected by a speculative read here.
            if !contents.imageURLs.isEmpty {
                let granted = reserveSlots(contents.imageURLs.count)
                if granted > 0 {
                    let urls = Array(contents.imageURLs.prefix(granted))
                    Task { @MainActor in
                        for url in urls { await addReserved(contentsOf: url) }
                    }
                }
                // Still "handled" even at cap or on a read failure: the
                // pasteboard held an image file, so falling through to a text
                // paste would insert its path.
                return true
            }
            if let data = contents.rawImage, reserveSlots(1) == 1 {
                Task { @MainActor in await addReserved(data: data, name: nil) }
            }
            return true
        }
    #endif
}
