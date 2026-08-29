import ChatCore
import Foundation
import Testing

// NOTE: no `import Mercury` — the app has no module; this test bundle
// compiles Mercury/ComposerAttachments.swift directly (project.yml).

private func staged(_ name: String = "a.png") -> PendingAttachment {
    PendingAttachment(filename: name, data: Data([0x01]), thumbnail: Data([0x02]))
}

@MainActor
@Suite("Composer attachment staging")
struct ComposerAttachmentsTests {
    // MARK: Send gate / budget

    @Test func inFlightPreparationsShrinkTheAvailableBudget() {
        let composer = ComposerAttachments()
        #expect(composer.availableSlots == ComposerAttachments.maxAttachments)
        #expect(!composer.isBusyPreparing)

        composer.reserveSlots(1)
        composer.reserveSlots(1)
        // The picker's budget and the Send gate both read these: with two
        // encodes in flight the tray has two fewer slots to offer, and the
        // composer is busy even though nothing is staged yet.
        #expect(composer.availableSlots == ComposerAttachments.maxAttachments - 2)
        #expect(composer.isBusyPreparing)
        #expect(composer.items.isEmpty)

        composer.append(staged())
        #expect(
            composer.availableSlots
                == ComposerAttachments.maxAttachments - composer.items.count - composer.preparing)
    }

    @Test func preparationsBalanceBackToIdle() {
        let composer = ComposerAttachments()
        composer.reserveSlots(1)
        composer.reserveSlots(1)
        composer.endPreparation()
        #expect(composer.isBusyPreparing)
        composer.endPreparation()
        #expect(composer.preparing == 0)
        #expect(!composer.isBusyPreparing)
        #expect(composer.availableSlots == ComposerAttachments.maxAttachments)
        // Never negative, however the exit paths interleave.
        composer.endPreparation()
        #expect(composer.preparing == 0)
    }

    @Test func failedPreparationReleasesTheSendGate() async {
        let composer = ComposerAttachments()
        #expect(composer.reserveSlots(1) == 1)
        // Not an image: `prepare` throws, and the error path must still run
        // the counter back down or Send stays disabled forever.
        await composer.addReserved(data: Data([0x00, 0x01, 0x02]), name: nil)
        #expect(composer.preparing == 0)
        #expect(!composer.isBusyPreparing)
        #expect(composer.items.isEmpty)
        #expect(composer.error != nil)
    }

    // MARK: Reservation at acquisition start

    @Test func reservingABatchShrinksTheBudgetImmediately() {
        let composer = ComposerAttachments()
        // The picker/drop/paste paths reserve the WHOLE batch before the
        // first byte is acquired: `loadTransferable` on an iCloud photo can
        // take seconds, and an unreserved acquisition window is exactly the
        // send race the counter exists to close.
        #expect(composer.reserveSlots(3) == 3)
        #expect(composer.preparing == 3)
        #expect(composer.isBusyPreparing)
        #expect(composer.availableSlots == ComposerAttachments.maxAttachments - 3)
        #expect(composer.items.isEmpty)
    }

    @Test func releasedReservationRestoresItsSlot() {
        let composer = ComposerAttachments()
        #expect(composer.reserveSlots(2) == 2)
        // One item's load failed (nil transferable, a throw, cancellation):
        // its slot goes back so the batch's other item isn't squeezed out.
        composer.endPreparation()
        #expect(composer.preparing == 1)
        #expect(composer.availableSlots == ComposerAttachments.maxAttachments - 1)
        composer.endPreparation()
        #expect(composer.preparing == 0)
        #expect(!composer.isBusyPreparing)
        #expect(composer.availableSlots == ComposerAttachments.maxAttachments)
    }

    @Test func overCapBatchReservesOnlyWhatIsAvailable() {
        let composer = ComposerAttachments()
        for index in 0..<3 { composer.append(staged("img-\(index).png")) }
        // Four dropped at once with three staged: only two slots exist.
        #expect(composer.reserveSlots(4) == 2)
        #expect(composer.preparing == 2)
        #expect(composer.availableSlots == 0)
        #expect(composer.error != nil)
        // And nothing is granted once there is no room at all.
        composer.error = nil
        #expect(composer.reserveSlots(2) == 0)
        #expect(composer.preparing == 2)
        #expect(composer.error != nil)
    }

    // MARK: Cap

    @Test func capRefusesTheSixthAppendWithoutLeakingPreparing() {
        let composer = ComposerAttachments()
        for index in 0..<ComposerAttachments.maxAttachments {
            #expect(composer.reserveSlots(1) == 1)
            #expect(composer.append(staged("img-\(index).png")))
            composer.endPreparation()
        }
        #expect(composer.items.count == ComposerAttachments.maxAttachments)
        #expect(composer.availableSlots == 0)

        // At cap the reservation is refused outright…
        #expect(composer.reserveSlots(1) == 0)
        #expect(composer.preparing == 0)
        #expect(composer.error != nil)

        // …and the append-time re-check refuses too, for the preparation that
        // was reserved while there was still room.
        composer.error = nil
        #expect(composer.append(staged("img-6.png")) == false)
        #expect(composer.items.count == ComposerAttachments.maxAttachments)
        #expect(composer.error != nil)
        #expect(composer.preparing == 0)
    }

    // MARK: Batch-scoped error

    @Test func failureEarlyInABatchSurvivesALaterSuccess() {
        let composer = ComposerAttachments()
        composer.beginBatch()
        // Item 1 of the batch failed to load.
        composer.error = "Couldn't load photo."
        // Item 2 succeeded — it must NOT wipe the first item's failure.
        #expect(composer.append(staged()))
        #expect(composer.error == "Couldn't load photo.")
    }

    // MARK: Security-scoped read

    @Test func readRefusesFilesOverTheSourceCapWithoutReadingThem() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-cap-\(UUID().uuidString).bin")
        try Data(repeating: 0x7f, count: 4096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // The stat happens inside the security scope, alongside the read.
        #expect(ComposerAttachments.readSecurityScoped(url, maxBytes: 1024) == .failure(.tooLarge))
        switch ComposerAttachments.readSecurityScoped(url, maxBytes: 8192) {
        case .success(let data): #expect(data.count == 4096)
        case .failure(let failure): Issue.record("expected bytes, got \(failure)")
        }
    }

    @Test func readReportsUnreadableFilesSeparately() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-missing-\(UUID().uuidString).png")
        #expect(
            ComposerAttachments.readSecurityScoped(
                missing, maxBytes: ComposerAttachments.maxSourceFileBytes)
                == .failure(.unreadable))
    }

    @Test func newBatchClearsThePreviousError() {
        let composer = ComposerAttachments()
        composer.error = "Couldn't load photo."
        composer.beginBatch()
        #expect(composer.error == nil)
    }

    @Test func clearResetsTrayAndError() {
        let composer = ComposerAttachments()
        composer.append(staged())
        composer.error = "Couldn't load photo."
        composer.clear()
        #expect(composer.items.isEmpty)
        #expect(composer.error == nil)
    }
}
