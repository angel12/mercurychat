import Foundation
import MercuryKit
import Testing

@testable import ChatCore

private func rows(_ text: String) -> [TranscriptMessage] {
    let value = try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    return value.arrayValue!.compactMap(TranscriptMessage.init(json:))
}

/// Issue #89: re-hydration reconciles live user echoes against persisted
/// rows by text and attachment count, and it counted EVERY row on the page
/// as a candidate — including rows already on screen before the echo was
/// sent. An old row with the same text then consumed a newer failed (or
/// still-sending) echo, and its bubble and retry control vanished. Only a
/// row that is new since the last hydration can be what an echo became.
@MainActor
@Suite("Hydration row identity (#89)")
struct HydrationRowIdentityTests {
    private static let history = #"""
        [{"id": 1, "role": "user", "content": "repeat"},
         {"id": 2, "role": "assistant", "content": "done"}]
        """#

    private func userRows(_ store: TranscriptStore) -> [UserMessage] {
        store.items.compactMap { item in
            if case .user(let message) = item { return message }
            return nil
        }
    }

    @Test func anOldRowDoesNotConsumeANewFailedEcho() {
        let store = TranscriptStore()
        store.hydrate(rows(Self.history))
        let failed = store.appendUserMessage("repeat", state: .failed)

        store.hydrate(rows(Self.history))

        #expect(userRows(store).map(\.id).contains(failed), "the failed repeat vanished")
        #expect(userRows(store).last?.sendState == .failed)
        #expect(userRows(store).count == 2)
    }

    @Test func anOldRowDoesNotConsumeAStillSendingEcho() {
        let store = TranscriptStore()
        store.hydrate(rows(Self.history))
        let sending = store.appendUserMessage("repeat", state: .sending)

        store.hydrate(rows(Self.history))
        // The send then fails: its echo must still be there to show retry.
        store.setUserMessageState(id: sending, .failed)

        let echo = userRows(store).first { $0.id == sending }
        #expect(echo != nil, "the in-flight repeat vanished")
        #expect(echo?.sendState == .failed)
    }

    @Test func anOldCaptionlessImageRowDoesNotConsumeANewFailedImageEcho() {
        // Captionless one-image sends all share the key "u:#1".
        let history = #"[{"id": 8, "role": "user", "content": "@image:/tmp/a.png"}]"#
        let store = TranscriptStore()
        store.hydrate(rows(history))
        let failed = store.appendUserMessage(
            "",
            attachments: [
                MessageAttachment(
                    id: "att-1", kind: .image, filename: "b.png", previewData: Data([0x01]))
            ],
            state: .failed)

        store.hydrate(rows(history))

        #expect(userRows(store).map(\.id).contains(failed), "the failed image send vanished")
    }

    @Test func anOldRowDoesNotConsumeANewFailedPDFEcho() {
        // PDF echoes claim on text alone, in their own pass.
        let history = #"[{"id": 9, "role": "user", "content": "the report\n@image:/tmp/p1.png\n@image:/tmp/p2.png"}]"#
        let store = TranscriptStore()
        store.hydrate(rows(history))
        let failed = store.appendUserMessage(
            "the report",
            attachments: [MessageAttachment(id: "att-2", kind: .pdf, filename: "report.pdf")],
            state: .failed)

        store.hydrate(rows(history))

        #expect(userRows(store).map(\.id).contains(failed), "the failed PDF send vanished")
    }

    @Test func aNewlyPersistedRowStillAcknowledgesItsEcho() {
        let store = TranscriptStore()
        store.hydrate(rows(Self.history))
        store.appendUserMessage("repeat", state: .sending)

        // The resend is persisted as a NEW row: it is what the echo became.
        store.hydrate(
            rows(
                #"""
                [{"id": 1, "role": "user", "content": "repeat"},
                 {"id": 2, "role": "assistant", "content": "done"},
                 {"id": 3, "role": "user", "content": "repeat"}]
                """#))

        #expect(userRows(store).count == 2, "the acknowledged echo was kept as a duplicate")
        #expect(userRows(store).allSatisfy { $0.rowID != nil })
    }
}
