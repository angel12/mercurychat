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

        composer.beginPreparation()
        composer.beginPreparation()
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
        composer.beginPreparation()
        composer.beginPreparation()
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
        // Not an image: `prepare` throws, and the error path must still run
        // the counter back down or Send stays disabled forever.
        await composer.add(data: Data([0x00, 0x01, 0x02]), name: nil)
        #expect(composer.preparing == 0)
        #expect(!composer.isBusyPreparing)
        #expect(composer.items.isEmpty)
        #expect(composer.error != nil)
    }

    // MARK: Cap

    @Test func capRefusesTheSixthAppendWithoutLeakingPreparing() {
        let composer = ComposerAttachments()
        for index in 0..<ComposerAttachments.maxAttachments {
            #expect(composer.beginPreparation())
            #expect(composer.append(staged("img-\(index).png")))
            composer.endPreparation()
        }
        #expect(composer.items.count == ComposerAttachments.maxAttachments)
        #expect(composer.availableSlots == 0)

        // At cap the reservation is refused outright…
        #expect(composer.beginPreparation() == false)
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
