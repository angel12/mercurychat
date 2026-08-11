import Foundation
import Testing
import MercuryKit

@testable import ChatCore

private func json(_ text: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

private func event(_ type: String, _ payload: String = "{}", session: String = "ab12cd34")
    -> GatewayEvent
{
    GatewayEvent(type: type, sessionID: session, payload: json(payload))
}

@MainActor
@Suite("TranscriptStore reduction")
struct TranscriptStoreTests {
    @Test func streamsASimpleTurn() {
        let store = TranscriptStore()
        store.appendUserMessage("hello")
        store.apply(event("session.info", #"{"running": true}"#))
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "Hel"}"#))
        store.apply(event("message.delta", #"{"text": "lo!"}"#))
        #expect(store.running)
        guard case .assistant(let streaming) = store.items.last else {
            Issue.record("expected assistant bubble")
            return
        }
        #expect(streaming.text == "Hello!")
        #expect(streaming.isStreaming)

        store.apply(event("message.complete", #"{"text": "Hello!", "status": "ok"}"#))
        store.apply(event("session.info", #"{"running": false}"#))
        #expect(!store.running)
        guard case .assistant(let done) = store.items.last else {
            Issue.record("expected assistant bubble")
            return
        }
        #expect(!done.isStreaming)
        #expect(done.error == nil)
        #expect(store.items.count == 2)
    }

    @Test func reasoningAccumulatesSeparately() {
        let store = TranscriptStore()
        store.apply(event("message.start"))
        store.apply(event("reasoning.delta", #"{"text": "thinking "}"#))
        store.apply(event("thinking.delta", #"{"text": "harder"}"#))
        store.apply(event("message.delta", #"{"text": "answer"}"#))
        guard case .assistant(let bubble) = store.items.last else {
            Issue.record("expected assistant bubble")
            return
        }
        #expect(bubble.reasoning == "thinking harder")
        #expect(bubble.text == "answer")
    }

    @Test func interimSealsAndNextDeltaOpensNewBubble() {
        let store = TranscriptStore()
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "first"}"#))
        store.apply(event("message.interim", #"{"text": "first", "already_streamed": true}"#))
        store.apply(event("message.delta", #"{"text": "second"}"#))
        let bubbles = store.items.compactMap { item -> AssistantMessage? in
            if case .assistant(let m) = item { return m }
            return nil
        }
        #expect(bubbles.count == 2)
        #expect(bubbles[0].text == "first")
        #expect(bubbles[0].isInterim)
        #expect(!bubbles[0].isStreaming)
        #expect(bubbles[1].text == "second")
        #expect(bubbles[1].isStreaming)
    }

    @Test func interimWithoutStreamedTextSetsText() {
        let store = TranscriptStore()
        store.apply(event("message.start"))
        store.apply(event("message.interim", #"{"text": "commentary", "already_streamed": false}"#))
        guard case .assistant(let bubble) = store.items.last else {
            Issue.record("expected assistant bubble")
            return
        }
        #expect(bubble.text == "commentary")
    }

    @Test func toolGeneratingIsHintNotRow() {
        let store = TranscriptStore()
        store.apply(event("tool.generating", #"{"name": "terminal"}"#))
        #expect(store.generatingToolName == "terminal")
        #expect(store.items.isEmpty)

        store.apply(
            event(
                "tool.start",
                #"{"tool_id": "t1", "name": "terminal", "context": "ls", "args_text": "{\"cmd\": \"ls\"}"}"#
            ))
        #expect(store.generatingToolName == nil)
        guard case .tool(let row) = store.items.last else {
            Issue.record("expected tool row")
            return
        }
        #expect(row.isRunning)
        #expect(row.name == "terminal")
        #expect(row.context == "ls")

        store.apply(
            event(
                "tool.complete",
                #"{"tool_id": "t1", "name": "terminal", "summary": "listed 4 files", "duration_s": 1.2, "result_text": "a b c d"}"#
            ))
        guard case .tool(let done) = store.items.last else {
            Issue.record("expected tool row")
            return
        }
        #expect(!done.isRunning)
        #expect(done.summary == "listed 4 files")
        #expect(done.durationSeconds == 1.2)
        #expect(done.resultText == "a b c d")
    }

    @Test func toolCompleteWithoutStartCreatesCollapsedRow() {
        // Reconnect mid-turn: the start event was on the dead socket.
        let store = TranscriptStore()
        store.apply(
            event("tool.complete", #"{"tool_id": "t9", "name": "web", "summary": "fetched"}"#))
        guard case .tool(let row) = store.items.last else {
            Issue.record("expected tool row")
            return
        }
        #expect(!row.isRunning)
        #expect(row.summary == "fetched")
    }

    @Test func errorCompleteKeepsPartialText() {
        let store = TranscriptStore()
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "partial answer"}"#))
        store.apply(
            event(
                "message.complete",
                #"{"text": "partial answer", "status": "error", "error": "provider 500", "partial": true}"#
            ))
        guard case .assistant(let bubble) = store.items.last else {
            Issue.record("expected assistant bubble")
            return
        }
        #expect(bubble.text == "partial answer")
        #expect(bubble.error == "provider 500")
        #expect(store.lastError == "provider 500")
    }

    @Test func blockingPromptsSurfaceAndClearOnTurnEnd() {
        let store = TranscriptStore()
        store.apply(
            event(
                "approval.request",
                #"{"command": "rm -rf build", "allow_permanent": false}"#))
        #expect(store.pendingApproval?.command == "rm -rf build")
        #expect(store.pendingApproval?.choices == ["once", "session", "deny"])

        store.apply(event("clarify.request", #"{"request_id": "c1", "question": "Which env?"}"#))
        #expect(store.pendingClarify?.question == "Which env?")

        store.apply(event("clarify.expire", #"{"request_id": "c1"}"#))
        #expect(store.pendingClarify == nil)

        store.apply(event("secret.request", #"{"request_id": "s1", "prompt": "API key?"}"#))
        #expect(store.pendingSecret != nil)

        store.apply(event("session.info", #"{"running": false}"#))
        #expect(store.pendingApproval == nil)
        #expect(store.pendingSecret == nil)
    }

    @Test func usageAccumulatesAcrossTurns() {
        let store = TranscriptStore()
        store.apply(
            event(
                "message.complete",
                #"{"text": "a", "usage": {"calls": 1, "input": 100, "output": 20, "total": 120}}"#
            ))
        store.apply(
            event(
                "message.complete",
                #"{"text": "b", "usage": {"calls": 2, "input": 300, "output": 60, "total": 360}}"#
            ))
        #expect(store.totalUsage.calls == 3)
        #expect(store.totalUsage.totalTokens == 480)
    }

    @Test func sessionInfoMetadataAndLazySkip() {
        let store = TranscriptStore()
        store.apply(event("session.info", #"{"lazy": true, "title": "placeholder"}"#))
        #expect(store.title == nil)

        store.apply(
            event(
                "session.info",
                #"{"title": "Fix the bug", "model": "hermes-4", "profile_name": "work", "stored_session_id": "20260811_120000_ab12", "running": true}"#
            ))
        #expect(store.title == "Fix the bug")
        #expect(store.model == "hermes-4")
        #expect(store.profileName == "work")
        #expect(store.storedSessionID == "20260811_120000_ab12")
        #expect(store.running)
    }

    @Test func unknownEventsAreTolerated() {
        let store = TranscriptStore()
        store.apply(event("pet.changed", #"{"mood": "happy"}"#))
        store.apply(event("some.future.event"))
        #expect(store.items.isEmpty)
    }

    @Test func subagentFlattensToLabeledRow() {
        let store = TranscriptStore()
        store.apply(
            event(
                "subagent.start",
                #"{"subagent_id": "sa1", "goal": "research the API", "task_count": 2, "task_index": 0}"#
            ))
        guard case .tool(let row) = store.items.last else {
            Issue.record("expected subagent row")
            return
        }
        #expect(row.isRunning)
        #expect(row.subagentLabel == "Subagent 1/2")
        #expect(row.context == "research the API")

        store.apply(
            event(
                "subagent.tool",
                #"{"subagent_id": "sa1", "tool_name": "web", "tool_preview": "GET /docs"}"#))
        store.apply(
            event(
                "subagent.complete",
                #"{"subagent_id": "sa1", "summary": "found 3 endpoints", "duration_seconds": 8.5}"#
            ))
        guard case .tool(let done) = store.items.last else {
            Issue.record("expected subagent row")
            return
        }
        #expect(!done.isRunning)
        #expect(done.summary == "found 3 endpoints")
        #expect(done.durationSeconds == 8.5)
    }
}

@MainActor
@Suite("TranscriptStore hydration")
struct TranscriptHydrationTests {
    private func rows(_ text: String) -> [TranscriptMessage] {
        json(text).arrayValue!.compactMap(TranscriptMessage.init(json:))
    }

    @Test func hydratesBasicTranscript() {
        let store = TranscriptStore()
        store.hydrate(
            rows(
                """
                [{"id": 1, "role": "user", "content": "hi"},
                 {"id": 2, "role": "assistant", "content": "hello", "reasoning": "greet"},
                 {"id": 3, "role": "tool", "tool_name": "terminal", "context": "ls", "content": "files"},
                 {"id": 4, "role": "system", "content": "internal"}]
                """))
        #expect(store.items.count == 3)  // system row dropped
        guard case .assistant(let bubble) = store.items[1] else {
            Issue.record("expected assistant")
            return
        }
        #expect(bubble.reasoning == "greet")
        #expect(bubble.rowID == 2)
    }

    @Test func hydrationDropsPersistedLiveEchoesKeepsStreaming() {
        let store = TranscriptStore()
        store.appendUserMessage("hi")
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "streaming still"}"#))

        // Re-hydration after reconnect: the user row is now persisted, the
        // assistant turn is still inflight.
        store.hydrate(rows(#"[{"id": 1, "role": "user", "content": "hi"}]"#))

        #expect(store.items.count == 2)
        guard case .user(let user) = store.items[0] else {
            Issue.record("expected hydrated user row first")
            return
        }
        #expect(user.rowID == 1)
        guard case .assistant(let bubble) = store.items[1] else {
            Issue.record("expected surviving live bubble")
            return
        }
        #expect(bubble.isStreaming)
        #expect(bubble.text == "streaming still")

        // The still-open bubble must keep receiving deltas after re-index.
        store.apply(event("message.delta", #"{"text": " more"}"#))
        guard case .assistant(let updated) = store.items[1] else {
            Issue.record("expected assistant")
            return
        }
        #expect(updated.text == "streaming still more")
    }

    @Test func prependOlderPagesAndDedupes() {
        let store = TranscriptStore()
        store.hydrate(rows(#"[{"id": 10, "role": "user", "content": "recent"}]"#))
        store.prependOlder(
            rows(
                """
                [{"id": 8, "role": "user", "content": "older"},
                 {"id": 10, "role": "user", "content": "recent"}]
                """))
        #expect(store.items.count == 2)
        guard case .user(let first) = store.items[0] else {
            Issue.record("expected user row")
            return
        }
        #expect(first.rowID == 8)
    }

    @Test func hiddenRowsAreSkipped() {
        let store = TranscriptStore()
        store.hydrate(
            rows(
                #"[{"id": 1, "role": "assistant", "content": "x", "display_kind": "hidden"}]"#))
        #expect(store.items.isEmpty)
    }
}

@MainActor
@Suite("Tool-boundary interleaving")
struct ToolInterleaveTests {
    @Test func textAfterToolOpensNewBubbleBelowRow() {
        let store = TranscriptStore()
        store.apply(event("message.start"))
        store.apply(event("reasoning.delta", #"{"text": "plan"}"#))
        store.apply(event("tool.start", #"{"tool_id": "t1", "name": "terminal", "context": "echo hi"}"#))
        store.apply(event("tool.complete", #"{"tool_id": "t1", "summary": "ran"}"#))
        store.apply(event("message.delta", #"{"text": "It printed hi."}"#))
        store.apply(event("message.complete", #"{"text": "It printed hi.", "status": "ok"}"#))

        // Order: sealed (reasoning-only) bubble, tool row, reply bubble.
        #expect(store.items.count == 3)
        guard case .tool = store.items[1] else {
            Issue.record("expected tool row in the middle")
            return
        }
        guard case .assistant(let reply) = store.items[2] else {
            Issue.record("expected reply bubble after the tool row")
            return
        }
        #expect(reply.text == "It printed hi.")
        #expect(!reply.isStreaming)
    }

    @Test func completeKeepsStreamedTextWhenPresent() {
        let store = TranscriptStore()
        store.apply(event("message.delta", #"{"text": "streamed"}"#))
        store.apply(event("message.complete", #"{"text": "streamed PLUS full echo", "status": "ok"}"#))
        guard case .assistant(let bubble) = store.items.last else {
            Issue.record("expected bubble")
            return
        }
        #expect(bubble.text == "streamed")
    }
}
