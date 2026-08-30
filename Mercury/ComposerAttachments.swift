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
///
/// Staging is per-kind (`MessageAttachment.Kind`): a picked/dropped file URL
/// is classified from its extension by `kind(forFilename:)`, and only `.image`
/// takes the decode/resize/encode path — `.pdf` and `.file` stage the raw
/// bytes with no thumbnail. Byte ceilings follow the kind too (`maxPDFBytes`
/// for PDFs, `maxSourceFileBytes` for everything else); the 5-attachment cap
/// is shared across kinds. Inputs that arrive as bare DATA (photo picker,
/// pasted/dropped screenshots) are images by construction and never classify.
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

    /// Server cap for `pdf.attach` payloads (error 4018 above 50 MB) —
    /// enforced from file metadata before the read, like the source cap.
    static let maxPDFBytes = 50 * 1024 * 1024

    /// Kind by declared type (filename extension via UTType). Intent-based on
    /// purpose: a `.txt` must never take the image decode path just because
    /// trial-decoding is possible, and raw pasted/picked image DATA (no
    /// filename) never reaches this — those inputs are inherently images.
    nonisolated static func kind(forFilename name: String) -> MessageAttachment.Kind {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .pdf }
        return .file
    }

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
            error = "Up to \(Self.maxAttachments) attachments per message."
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
            error = "Up to \(Self.maxAttachments) attachments per message."
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
    ///
    /// The kind is decided from the filename BEFORE the read, because the byte
    /// ceiling depends on it: PDFs are capped by the server's `pdf.attach`
    /// limit, everything else by the source cap.
    func addReserved(contentsOf url: URL) async {
        defer { endPreparation() }
        let kind = Self.kind(forFilename: url.lastPathComponent)
        let maxBytes = kind == .pdf ? Self.maxPDFBytes : Self.maxSourceFileBytes
        // Whole-file read off the MainActor too: a big image on a slow volume
        // blocks just as long as the encode did.
        let outcome = await Task.detached {
            Self.readSecurityScoped(url, maxBytes: maxBytes)
        }.value
        switch outcome {
        case .success(let data):
            switch kind {
            case .image:
                // `fileFallbackName`: an image-TYPED file ImageIO can't decode
                // (`.svg`, `.ai`) still attaches, as a plain file.
                await prepareAndAppend(
                    data: data, name: url.lastPathComponent,
                    fileFallbackName: url.lastPathComponent)
            case .pdf, .file:
                // No transcode for non-images: raw bytes go on the wire, and
                // there is no thumbnail — the tray/transcript render a chip.
                append(PendingAttachment(filename: url.lastPathComponent, data: data, kind: kind))
            }
        case .failure(.tooLarge):
            error =
                kind == .pdf
                ? "PDF is too large to send (50 MB max)."
                : (kind == .image
                    ? "Image is too large to send (60 MB max)."
                    : "File is too large to send (60 MB max).")
        case .failure(.unreadable):
            error = "Couldn't read \(url.lastPathComponent)."
        }
    }

    /// Encode + append for a preparation whose slot is already reserved.
    ///
    /// `fileFallbackName` is the escape hatch for a file whose DECLARED type
    /// is an image but whose bytes ImageIO refuses — `.svg` and `.ai` both
    /// conform to `public.image` yet neither decodes. Those were a dead end:
    /// the user attached a file, saw "That doesn't look like an image.", and
    /// had no way to send it. With a name supplied, `.notAnImage` instead
    /// stages the raw bytes as `.file`, exactly as an unclassified file would.
    /// Every other error (`.tooLarge` included) still surfaces, and the raw
    /// DATA paths (paste, screenshot drop) pass nil: bytes with no filename
    /// are only ever offered as images, so undecodable bytes there are a real
    /// failure with no file to fall back to.
    ///
    /// The append consumes the caller's reservation the same way the image
    /// path does — the caller's `defer` releases it, and `append` re-checks
    /// the cap.
    private func prepareAndAppend(
        data: Data, name: String?, fileFallbackName: String? = nil
    ) async {
        do {
            let prepared = try await Task.detached {
                try ImageAttachmentPreparer.prepare(data: data, suggestedName: name)
            }.value
            append(prepared)
        } catch {
            if case ImagePreparationError.notAnImage = error, let fileFallbackName {
                append(PendingAttachment(filename: fileFallbackName, data: data, kind: .file))
                return
            }
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
    /// A file URL of ANY type attaches — `addReserved(contentsOf:)` classifies
    /// it and applies that kind's cap. The raw-data fallback stays image-only:
    /// bytes with no filename carry no declared type to classify, and the only
    /// providers that reach it are screenshots and dragged image data.
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
        /// ⌘V handler (#4). Returns true when the pasteboard held attachable
        /// content — a file of ANY kind, or raw image bytes — even at cap or
        /// on a read failure, since falling through to a text paste would
        /// insert the file's path. False for a plain text paste (and for a
        /// copied browser link), which is never swallowed.
        @discardableResult
        func pasteAttachments(from pasteboard: NSPasteboard = .general) -> Bool {
            let contents = ImagePasteboardReader.read(pasteboard)
            // A plain TEXT ⌘V is not a batch: returning `.ignored` from here
            // hands the paste to the field editor, so clearing the error line
            // on the way out would wipe a visible attachment failure that the
            // user never acted on. Only attachable content starts a batch.
            guard !contents.isEmpty else { return false }
            beginBatch()
            // Pasted FILES take the same off-main, size-capped read as a drop
            // (#2): the reader classifies on the MainActor and hands the disk
            // hit to `addReserved(contentsOf:)`, which picks the kind's ceiling
            // (the PDF cap for PDFs, the source cap otherwise) and stats
            // against it inside the security scope before reading a byte.
            // Reading here instead froze the composer for the length of a
            // large paste and skipped the cap entirely.
            //
            // Images and other files are ONE batch against ONE reservation —
            // the 5-attachment cap is shared across kinds, so reserving each
            // list separately would hand out the same free slots twice. A
            // single task awaits them in order, keeping a multi-file paste
            // staged in pasteboard order (images first) with no gap between
            // items. Unreadable files surface their "Couldn't read …" error
            // from that same path rather than a speculative read here.
            let urls = contents.imageURLs + contents.fileURLs
            if !urls.isEmpty {
                let granted = reserveSlots(urls.count)
                if granted > 0 {
                    let reserved = Array(urls.prefix(granted))
                    Task { @MainActor in
                        for url in reserved { await addReserved(contentsOf: url) }
                    }
                }
                // Still "handled" even at cap or on a read failure: the
                // pasteboard held a file, so falling through to a text paste
                // would insert its path.
                return true
            }
            if let data = contents.rawImage, reserveSlots(1) == 1 {
                Task { @MainActor in await addReserved(data: data, name: nil) }
            }
            return true
        }
    #endif
}
