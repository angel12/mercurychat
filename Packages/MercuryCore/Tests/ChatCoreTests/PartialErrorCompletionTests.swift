import Foundation
import Testing
import MercuryKit

@testable import ChatCore

// #110: an error `message.complete` carrying `partial: true` means the
// backend streamed that text as deltas — but if THIS client never applied
// them (event-loss gap not recovered by replay), the completion's `text` is
// the only copy of the answer and must not be dropped. When the deltas DID
// land this turn, the text is already on screen (possibly split across
// bubbles sealed at tool boundaries) and copying it would duplicate it.

private func json(_ text: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

private func event(_ type: String, _ payload: String = "{}", session: String = "ab12cd34")
    -> GatewayEvent
{
    GatewayEvent(type: type, sessionID: session, payload: json(payload))
}

private let partialError =
    #"{"text": "the answer", "status": "error", "error": "provider 500", "partial": true}"#

@MainActor
private func assistantTexts(_ store: TranscriptStore) -> [String] {
    store.items.compactMap { item in
        if case .assistant(let m) = item { return m.text }
        return nil
    }
}

@MainActor
@Suite("Partial error completion (#110)")
struct PartialErrorCompletionTests {
    @Test func partialErrorWithNoDeltasKeepsTextAndError() {
        let store = TranscriptStore()
        store.appendUserMessage("q")
        store.apply(event("message.start"))
        // Every message.delta was lost in transit.
        store.apply(event("message.complete", partialError))
        guard case .assistant(let bubble) = store.items.last else {
            Issue.record("expected assistant bubble")
            return
        }
        #expect(bubble.text == "the answer")
        #expect(bubble.error == "provider 500")
        #expect(!bubble.isStreaming)
        #expect(store.lastError == "provider 500")
    }

    @Test func partialErrorWithNoStartAndNoDeltasKeepsText() {
        // Reconnect gap swallowed message.start too: no open bubble at all.
        let store = TranscriptStore()
        store.appendUserMessage("q")
        store.apply(event("message.complete", partialError))
        #expect(assistantTexts(store) == ["the answer"])
        guard case .assistant(let bubble) = store.items.last else {
            Issue.record("expected assistant bubble")
            return
        }
        #expect(bubble.error == "provider 500")
    }

    @Test func partialErrorAfterToolBoundaryDoesNotDuplicate() {
        let store = TranscriptStore()
        store.appendUserMessage("q")
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "the answer"}"#))
        store.apply(event("tool.start", #"{"tool_id": "t1", "name": "web"}"#))
        store.apply(event("tool.complete", #"{"tool_id": "t1", "name": "web"}"#))
        store.apply(event("message.complete", partialError))
        #expect(assistantTexts(store).joined() == "the answer")
        #expect(store.lastError == "provider 500")
        let errored = store.items.contains { item in
            if case .assistant(let m) = item { return m.error == "provider 500" }
            return false
        }
        #expect(errored)
    }

    @Test func partialErrorAfterRestoredInflightTextDoesNotDuplicate() {
        // Reconnect: the resume snapshot restored the streamed text, then a
        // tool boundary sealed it before the error completion.
        let store = TranscriptStore()
        store.appendUserMessage("q")
        store.apply(event("message.start"))
        store.restoreInflight(user: "q", assistant: "the answer", streaming: true)
        store.apply(event("tool.start", #"{"tool_id": "t1", "name": "web"}"#))
        store.apply(event("message.complete", partialError))
        #expect(assistantTexts(store).joined() == "the answer")
        #expect(store.lastError == "provider 500")
    }

    @Test func streamedFlagResetsOnNextMessageStart() {
        let store = TranscriptStore()
        // Turn 1 streams normally.
        store.appendUserMessage("first")
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "one"}"#))
        store.apply(event("message.complete", #"{"text": "one", "status": "ok"}"#))
        store.apply(event("session.info", #"{"running": false}"#))
        // Turn 2 loses its deltas and fails partway.
        store.appendUserMessage("second")
        store.apply(event("message.start"))
        store.apply(event("message.complete", partialError))
        #expect(assistantTexts(store) == ["one", "the answer"])
        guard case .assistant(let bubble) = store.items.last else {
            Issue.record("expected assistant bubble")
            return
        }
        #expect(bubble.error == "provider 500")
    }

    @Test func streamedFlagResetsOnChainedMessageStart() {
        // A chained turn: message.complete then message.start with no
        // session.info settle in between — message.start alone must reset.
        let store = TranscriptStore()
        store.appendUserMessage("q")
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "one"}"#))
        store.apply(event("message.complete", #"{"text": "one", "status": "ok"}"#))
        store.apply(event("message.start"))
        store.apply(event("message.complete", partialError))
        #expect(assistantTexts(store) == ["one", "the answer"])
    }

    @Test func streamedFlagResetsAtTurnEndWhenNextStartIsLost() {
        // Turn 1 settled; turn 2's message.start AND deltas were lost.
        let store = TranscriptStore()
        store.appendUserMessage("first")
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "one"}"#))
        store.apply(event("message.complete", #"{"text": "one", "status": "ok"}"#))
        store.apply(event("session.info", #"{"running": false}"#))
        store.appendUserMessage("second")
        store.apply(event("message.complete", partialError))
        #expect(assistantTexts(store) == ["one", "the answer"])
    }
}
