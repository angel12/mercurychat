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

    @Test func userEchoCounterTracksLiveEchoesOnly() {
        let store = TranscriptStore()
        #expect(store.userEchoCounter == 0)
        // Live echoes bump the counter — the transcript view keys its
        // snap-to-bottom on it (items.count coalescing can hide the echo).
        store.appendUserMessage("first")
        #expect(store.userEchoCounter == 1)
        store.restoreQueuedPrompt("queued while busy")
        #expect(store.userEchoCounter == 2)
        // Hydration replaces history without bumping: a reconnect must not
        // yank a reader who scrolled away back to the bottom.
        store.hydrate([
            TranscriptMessage(json: json(#"{"role": "user", "content": "old", "id": 1}"#))!,
            TranscriptMessage(json: json(#"{"role": "assistant", "content": "reply", "id": 2}"#))!,
        ])
        #expect(store.userEchoCounter == 2)
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

    @Test func staleResponseCannotClearNewerPrompt() {
        // Actor reentrancy: while response A's RPC is in flight, request B
        // replaces the pending prompt — A's confirmation must not clear B.
        let store = TranscriptStore()
        store.apply(event("clarify.request", #"{"request_id": "c1", "question": "A?"}"#))
        store.apply(event("clarify.request", #"{"request_id": "c2", "question": "B?"}"#))
        store.clearClarify(requestID: "c1")
        #expect(store.pendingClarify?.requestID == "c2")
        store.clearClarify(requestID: "c2")
        #expect(store.pendingClarify == nil)

        store.apply(event("approval.request", #"{"command": "rm old"}"#))
        let first = store.pendingApproval!
        store.apply(event("approval.request", #"{"command": "rm new"}"#))
        store.clearApproval(matching: first)
        #expect(store.pendingApproval?.command == "rm new")
        store.clearApproval(matching: store.pendingApproval!)
        #expect(store.pendingApproval == nil)
    }

    @Test func approvalCarriesOptionalRequestID() {
        let store = TranscriptStore()
        store.apply(event("approval.request", #"{"command": "ls", "request_id": "ap1"}"#))
        #expect(store.pendingApproval?.requestID == "ap1")
        // Older backends omit it — session-keyed respond still works.
        store.apply(event("approval.request", #"{"command": "ls"}"#))
        #expect(store.pendingApproval?.requestID == nil)
    }

    @Test func mcpSetupRequestLifecycle() {
        let store = TranscriptStore()
        store.apply(
            event(
                "mcp.setup.request",
                #"{"request_id": "m1", "server": "linear", "action": "install", "reason": "To read the ticket you linked"}"#
            ))
        #expect(store.pendingMcpSetup?.server == "linear")
        #expect(store.pendingMcpSetup?.action == "install")

        // An expire for a DIFFERENT request must not clear the card.
        store.apply(event("mcp.setup.expire", #"{"request_id": "other"}"#))
        #expect(store.pendingMcpSetup != nil)
        store.apply(event("mcp.setup.expire", #"{"request_id": "m1"}"#))
        #expect(store.pendingMcpSetup == nil)

        // Cleared at end of turn like every blocking prompt.
        store.apply(
            event("mcp.setup.request", #"{"request_id": "m2", "server": "notion"}"#))
        store.apply(event("session.info", #"{"running": false}"#))
        #expect(store.pendingMcpSetup == nil)
    }

    @Test func usageSnapshotsReplaceNotSum() {
        // The server's usage counters are session-cumulative on BOTH
        // message.complete and the mid-turn session.usage ticks — the second
        // snapshot already contains the first turn's tokens.
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
        #expect(store.sessionUsage?.calls == 2)
        #expect(store.sessionUsage?.totalTokens == 360)
    }

    @Test func sessionUsageTicksUpdateLiveSnapshot() {
        let store = TranscriptStore()
        store.apply(
            event(
                "session.usage",
                #"{"usage": {"calls": 1, "input": 50, "output": 10, "total": 60, "context_used": 8000, "context_max": 128000, "context_percent": 6}}"#
            ))
        #expect(store.sessionUsage?.totalTokens == 60)
        #expect(store.sessionUsage?.contextPercent == 6)
        #expect(store.sessionUsage?.contextMax == 128000)
        // A malformed tick must not wipe the last good snapshot.
        store.apply(event("session.usage", #"{}"#))
        #expect(store.sessionUsage?.totalTokens == 60)
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

    @Test func echoCarriesAttachments() {
        let store = TranscriptStore()
        let attachment = MessageAttachment(
            id: "att-1", kind: .image, filename: "photo.jpg",
            previewData: Data([0xFF, 0xD8]))
        store.appendUserMessage("look at this", attachments: [attachment], state: .sending)
        guard case .user(let message) = store.items.last else {
            Issue.record("expected user echo")
            return
        }
        #expect(message.attachments == [attachment])
        #expect(message.sendState == .sending)
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

    @Test func reconnectRestoreDoesNotDuplicateInflightTurn() {
        // Stream part of a turn, drop the socket, re-hydrate, and restore the
        // same inflight snapshot: exactly one user/assistant pair remains.
        let store = TranscriptStore()
        store.appendUserMessage("do the thing")
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "working on"}"#))

        // Reconnect: the user row persisted server-side; the turn is inflight.
        store.hydrate(rows(#"[{"id": 1, "role": "user", "content": "do the thing"}]"#))
        store.restoreInflight(
            user: "do the thing", assistant: "working on it", streaming: true)

        #expect(store.items.count == 2)
        guard case .user(let user) = store.items[0] else {
            Issue.record("expected single user row")
            return
        }
        #expect(user.text == "do the thing")
        guard case .assistant(let bubble) = store.items[1] else {
            Issue.record("expected single assistant bubble")
            return
        }
        // The snapshot is authoritative for text emitted while the socket
        // was down (missed deltas are never replayed): it extends the
        // streamed prefix, so the missing suffix is appended.
        #expect(bubble.text == "working on it")
        #expect(bubble.isStreaming)

        // The surviving bubble must still receive deltas.
        store.apply(event("message.delta", #"{"text": " now"}"#))
        guard case .assistant(let updated) = store.items[1] else {
            Issue.record("expected assistant")
            return
        }
        #expect(updated.text == "working on it now")
    }

    @Test func turnCompletedOfflineDropsStalePartialBubble() {
        // The turn finished while the socket was down: hydration already
        // carries the persisted final reply, and resume reports idle with
        // no inflight payload — the stale partial must not linger.
        let store = TranscriptStore()
        store.appendUserMessage("question")
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "final ans"}"#))

        store.hydrate(
            rows(
                """
                [{"id": 1, "role": "user", "content": "question"},
                 {"id": 2, "role": "assistant", "content": "final answer"}]
                """))
        store.setRunning(false)

        let assistants = store.items.compactMap { item -> AssistantMessage? in
            if case .assistant(let m) = item { return m }
            return nil
        }
        #expect(assistants.count == 1)
        #expect(assistants[0].text == "final answer")
        #expect(!assistants[0].isStreaming)
        #expect(store.items.count == 2)
    }

    @Test func setRunningFalseSealsUnmatchedSurvivor() {
        // The partial can't be lined up with the persisted reply (not a
        // prefix) — it survives, but must at least stop claiming to stream.
        let store = TranscriptStore()
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "some other tangent"}"#))
        store.hydrate(rows(#"[{"id": 2, "role": "assistant", "content": "final answer"}]"#))
        store.setRunning(false)

        for item in store.items {
            if case .assistant(let m) = item { #expect(!m.isStreaming) }
        }
        #expect(!store.running)
    }

    @Test func snapshotRestoresTextEmittedWhileDisconnected() {
        // Hermes kept generating while the socket was down; the resume
        // snapshot is the only carrier of the missing suffix.
        let store = TranscriptStore()
        store.appendUserMessage("question")
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "working"}"#))

        store.hydrate(rows("[]"))
        store.restoreInflight(
            user: "question", assistant: "working while offline", streaming: true)

        guard case .assistant(let bubble) = store.items.last else {
            Issue.record("expected assistant bubble")
            return
        }
        #expect(bubble.text == "working while offline")
        #expect(bubble.isStreaming)
    }

    @Test func snapshotSuffixRespectsToolBoundaryBubbles() {
        // The snapshot is the whole turn's text; bubbles sealed at tool
        // boundaries already hold their parts — only the suffix past the
        // rendered total may be appended, and only to the open bubble.
        let store = TranscriptStore()
        store.appendUserMessage("go")
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "first. "}"#))
        store.apply(event("tool.start", #"{"tool_id": "t1", "name": "terminal"}"#))
        store.apply(event("tool.complete", #"{"tool_id": "t1", "summary": "ran"}"#))
        store.apply(event("message.delta", #"{"text": "second"}"#))

        store.hydrate(rows("[]"))
        store.restoreInflight(
            user: "go", assistant: "first. second half", streaming: true)

        let assistants = store.items.compactMap { item -> AssistantMessage? in
            if case .assistant(let m) = item { return m }
            return nil
        }
        #expect(assistants.map(\.text) == ["first. ", "second half"])
        #expect(assistants.last?.isStreaming == true)
    }

    @Test func unalignableSnapshotKeepsStreamedText() {
        let store = TranscriptStore()
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "alpha"}"#))
        store.restoreInflight(user: "", assistant: "beta gamma", streaming: true)

        guard case .assistant(let bubble) = store.items.last else {
            Issue.record("expected assistant bubble")
            return
        }
        #expect(bubble.text == "alpha")
        #expect(bubble.isStreaming)
    }

    @Test func duplicateCorrectionsInSnapshotAppendOnce() {
        let store = TranscriptStore()
        store.restoreInflight(
            user: "base", corrections: ["same correction", "same correction"],
            assistant: "", streaming: true)

        let userTexts = store.items.compactMap { item -> String? in
            if case .user(let m) = item { return m.text }
            return nil
        }
        #expect(userTexts == ["base", "same correction"])
    }

    @Test func sealedReplyMatchAdoptsSnapshotError() {
        // The reply sealed just before the drop; the snapshot carries the
        // turn's error — it must attach to the existing bubble, not vanish
        // (and no twin bubble may appear).
        let store = TranscriptStore()
        store.appendUserMessage("hi")
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "done"}"#))
        store.apply(event("message.complete", #"{"text": "done", "status": "ok"}"#))

        store.hydrate(rows("[]"))
        store.restoreInflight(
            user: "hi", assistant: "done", streaming: false, error: "provider died")

        let assistants = store.items.compactMap { item -> AssistantMessage? in
            if case .assistant(let m) = item { return m }
            return nil
        }
        #expect(assistants.count == 1)
        #expect(assistants[0].error == "provider died")
        #expect(store.lastError == "provider died")
    }

    @Test func reconnectRestoreSkipsCorrectionsAlreadyEchoed() {
        let store = TranscriptStore()
        store.appendUserMessage("do the thing")
        store.appendUserMessage("actually use option B")
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "ok"}"#))

        store.hydrate(rows("[]"))
        store.restoreInflight(
            user: "do the thing", corrections: ["actually use option B"],
            assistant: "ok", streaming: true)

        let userTexts = store.items.compactMap { item -> String? in
            if case .user(let m) = item { return m.text }
            return nil
        }
        #expect(userTexts == ["do the thing", "actually use option B"])
        #expect(store.items.count == 3)
    }

    @Test func freshRestoreStillAppendsInflightTurn() {
        // App relaunch: nothing on screen yet — restore must build the turn.
        let store = TranscriptStore()
        store.hydrate(rows(#"[{"id": 1, "role": "user", "content": "earlier"}]"#))
        store.restoreInflight(
            user: "new prompt", assistant: "partial reply", streaming: true)

        #expect(store.items.count == 3)
        guard case .assistant(let bubble) = store.items[2] else {
            Issue.record("expected restored bubble")
            return
        }
        #expect(bubble.text == "partial reply")
        #expect(bubble.isStreaming)
    }

    @Test func restoreWithSealedReplyAlreadyPresentDoesNotAppendTwin() {
        // The turn finished (bubble sealed) right as the socket dropped; the
        // resume snapshot carries the same final text with streaming=false.
        let store = TranscriptStore()
        store.appendUserMessage("hi")
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "done"}"#))
        store.apply(event("message.complete", #"{"text": "done", "status": "ok"}"#))

        store.hydrate(rows("[]"))
        store.restoreInflight(user: "hi", assistant: "done", streaming: false)

        let bubbles = store.items.filter {
            if case .assistant = $0 { return true }
            return false
        }
        #expect(bubbles.count == 1)
    }

    @Test func restoreAfterToolStartDoesNotDuplicateAssistantText() {
        // Reconnect lands after tool.start sealed the bubble but before any
        // post-tool delta: the tool row is last, so neither the open-bubble
        // nor the sealed-last reconciliation path applies. The snapshot text
        // is already fully rendered — nothing may be appended (#9).
        let store = TranscriptStore()
        store.appendUserMessage("go")
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "first"}"#))
        store.apply(event("tool.start", #"{"tool_id": "t1", "name": "terminal"}"#))

        store.hydrate(rows("[]"))
        store.restoreInflight(user: "go", assistant: "first", streaming: true)

        let assistants = store.items.compactMap { item -> AssistantMessage? in
            if case .assistant(let m) = item { return m }
            return nil
        }
        #expect(assistants.map(\.text) == ["first"])

        // A post-tool delta still opens a fresh bubble below the tool row.
        store.apply(event("message.delta", #"{"text": "second"}"#))
        guard case .assistant(let post) = store.items.last else {
            Issue.record("expected post-tool bubble")
            return
        }
        #expect(post.text == "second")
    }

    @Test func restoreAfterToolStartAppendsOnlySnapshotSuffix() {
        // Same boundary, but the snapshot carries text emitted while the
        // socket was down — only the suffix past the rendered total may
        // appear, in a new streaming bubble below the tool row.
        let store = TranscriptStore()
        store.appendUserMessage("go")
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "first"}"#))
        store.apply(event("tool.start", #"{"tool_id": "t1", "name": "terminal"}"#))

        store.hydrate(rows("[]"))
        store.restoreInflight(user: "go", assistant: "firstsecond", streaming: true)

        let assistants = store.items.compactMap { item -> AssistantMessage? in
            if case .assistant(let m) = item { return m }
            return nil
        }
        #expect(assistants.map(\.text) == ["first", "second"])
        #expect(assistants.last?.isStreaming == true)
        guard case .tool = store.items[2] else {
            Issue.record("expected tool row between the segments")
            return
        }
    }

    @Test func restoreWithPersistedMidTurnSegmentsAppendsOnlySuffix() {
        // A mid-turn redirect (message sent while the agent runs) persists
        // the partial reply and the correction as rows. On reconnect the
        // hydrated turn already shows them; the snapshot concatenates the
        // whole turn and must not be appended verbatim below the correction
        // (#5: "my message appears again under the latest response").
        let store = TranscriptStore()
        store.hydrate(
            rows(
                """
                [{"id": 1, "role": "user", "content": "build it"},
                 {"id": 2, "role": "assistant", "content": "part one. "},
                 {"id": 3, "role": "user", "content": "use option B"}]
                """))
        store.restoreInflight(
            user: "build it", corrections: ["use option B"],
            assistant: "part one. part two", streaming: true)

        let userTexts = store.items.compactMap { item -> String? in
            if case .user(let m) = item { return m.text }
            return nil
        }
        #expect(userTexts == ["build it", "use option B"])

        let assistants = store.items.compactMap { item -> AssistantMessage? in
            if case .assistant(let m) = item { return m }
            return nil
        }
        #expect(assistants.map(\.text) == ["part one. ", "part two"])
        // The suffix renders BELOW the correction, matching emission order.
        guard case .assistant(let last) = store.items.last else {
            Issue.record("expected suffix bubble last")
            return
        }
        #expect(last.text == "part two")
        #expect(last.isStreaming)
    }

    @Test func restoreWithFullyRenderedTurnAppendsNothing() {
        // Rendered segments already account for the whole snapshot (sealed
        // at an interim/tool boundary, correction echo last): no append.
        let store = TranscriptStore()
        store.hydrate(
            rows(
                """
                [{"id": 1, "role": "user", "content": "build it"},
                 {"id": 2, "role": "assistant", "content": "part one"},
                 {"id": 3, "role": "user", "content": "use option B"}]
                """))
        let before = store.items.count
        store.restoreInflight(
            user: "build it", corrections: ["use option B"],
            assistant: "part one", streaming: true)
        #expect(store.items.count == before)
    }

    @Test func restoreUnalignableRenderedTurnKeepsSegments() {
        // The rendered turn can't be lined up with the snapshot (mid-turn
        // deltas were lost): keep what's on screen, never append a twin.
        let store = TranscriptStore()
        store.appendUserMessage("go")
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "tangent"}"#))
        store.apply(event("tool.start", #"{"tool_id": "t1", "name": "terminal"}"#))

        store.hydrate(rows("[]"))
        store.restoreInflight(user: "go", assistant: "different text", streaming: true)

        let assistants = store.items.compactMap { item -> AssistantMessage? in
            if case .assistant(let m) = item { return m }
            return nil
        }
        #expect(assistants.map(\.text) == ["tangent"])
    }

    @Test func hydrationDropsStreamingBubbleMatchingPersistedSegment() {
        // A turn with a mid-turn redirect completed while the socket was
        // down: the live partial equals a PERSISTED mid-turn segment (not a
        // prefix of the latest reply). It must not survive as a duplicate
        // under the final response (#5).
        let store = TranscriptStore()
        store.appendUserMessage("build it")
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "part one"}"#))

        store.hydrate(
            rows(
                """
                [{"id": 1, "role": "user", "content": "build it"},
                 {"id": 2, "role": "assistant", "content": "part one"},
                 {"id": 3, "role": "user", "content": "use option B"},
                 {"id": 4, "role": "assistant", "content": "part two final"}]
                """))
        store.setRunning(false)

        let assistants = store.items.compactMap { item -> AssistantMessage? in
            if case .assistant(let m) = item { return m }
            return nil
        }
        #expect(assistants.map(\.text) == ["part one", "part two final"])
        #expect(store.items.count == 4)
    }

    @Test func idleResumeReconcilesRunningToolWithPersistedRow() {
        // A tool completed while the socket was down: hydration carries the
        // persisted completed row (same tool_call_id) and resume reports
        // idle. Exactly one non-running row must remain — not a persisted
        // copy plus a live twin spinning forever (#10).
        let store = TranscriptStore()
        store.appendUserMessage("go")
        store.apply(event("message.start"))
        store.apply(event("tool.start", #"{"tool_id": "t1", "name": "terminal"}"#))

        store.hydrate(
            rows(
                """
                [{"id": 1, "role": "user", "content": "go"},
                 {"id": 2, "role": "tool", "tool_name": "terminal",
                  "tool_call_id": "t1", "content": "ran fine"}]
                """))
        store.setRunning(false)

        let tools = store.items.compactMap { item -> ToolActivity? in
            if case .tool(let t) = item { return t }
            return nil
        }
        #expect(tools.count == 1)
        #expect(tools[0].isRunning == false)
        #expect(tools[0].resultText == "ran fine")
    }

    @Test func idleWithoutPersistedRowStillSealsRunningTool() {
        // The completion event was lost AND the row isn't persisted (or has
        // no matching id): end-of-turn cleanup must still stop the spinner.
        let store = TranscriptStore()
        store.apply(event("tool.start", #"{"tool_id": "t1", "name": "terminal"}"#))
        store.apply(
            event(
                "subagent.start",
                #"{"subagent_id": "sa1", "goal": "explore", "task_index": 0, "task_count": 1}"#
            ))
        store.setRunning(false)

        for item in store.items {
            if case .tool(let t) = item { #expect(!t.isRunning) }
        }

        // A late completion for the sealed row must not crash or revive it.
        store.apply(event("tool.complete", #"{"tool_id": "t1", "summary": "late"}"#))
        let tools = store.items.compactMap { item -> ToolActivity? in
            if case .tool(let t) = item { return t }
            return nil
        }
        #expect(tools.allSatisfy { !$0.isRunning })
    }

    @Test func subagentIdentitySurvivesHydrationAndPagination() {
        // Progress/completion events key by subagent_id; the display label
        // ("Subagent") must never become the reducer identity across a
        // hydration or prepend reindex (#12).
        let store = TranscriptStore()
        store.apply(
            event(
                "subagent.start",
                #"{"subagent_id": "sa1", "goal": "explore", "task_index": 0, "task_count": 2}"#
            ))
        store.hydrate(rows("[]"))
        store.prependOlder(rows(#"[{"id": 1, "role": "user", "content": "earlier"}]"#))

        store.apply(
            event("subagent.complete", #"{"subagent_id": "sa1", "summary": "found it"}"#))

        let subagents = store.items.compactMap { item -> ToolActivity? in
            if case .tool(let t) = item, t.subagentLabel != nil { return t }
            return nil
        }
        #expect(subagents.count == 1)
        #expect(subagents[0].isRunning == false)
        #expect(subagents[0].summary == "found it")
    }

    @Test func echoStateTracksIdentityNotText() {
        // Two echoes with identical text: marking one failed must not touch
        // the other (#17 — stable submission identity).
        let store = TranscriptStore()
        let first = store.appendUserMessage("same", state: .sending)
        let second = store.appendUserMessage("same", state: .sending)
        store.setUserMessageState(id: first, .failed)
        store.setUserMessageState(id: second, .sent)

        let states = store.items.compactMap { item -> UserMessage.SendState? in
            if case .user(let m) = item { return m.sendState }
            return nil
        }
        #expect(states == [.failed, .sent])
    }

    @Test func queuedPromptRestoresOnceAndSettlesWhenTurnStarts() {
        let store = TranscriptStore()
        store.appendUserMessage("current turn")
        store.apply(event("message.start"))
        store.apply(event("message.delta", #"{"text": "working"}"#))

        // Fresh app open: no echo for the queued prompt — restore it.
        store.restoreQueuedPrompt("next thing")
        // A second resume (reconnect) must not duplicate it.
        store.restoreQueuedPrompt("next thing")

        let queued = store.items.compactMap { item -> UserMessage? in
            if case .user(let m) = item, m.sendState == .queued { return m }
            return nil
        }
        #expect(queued.map(\.text) == ["next thing"])

        // Its turn starting drains the queue: the chip settles to sent.
        store.apply(event("message.start"))
        let states = store.items.compactMap { item -> UserMessage.SendState? in
            if case .user(let m) = item { return m.sendState }
            return nil
        }
        #expect(!states.contains(.queued))
    }

    @Test func queuedPromptSkippedWhenEchoSurvived() {
        // Socket-drop reconnect: the local echo survived — the resume's
        // queued payload must not append a twin.
        let store = TranscriptStore()
        store.appendUserMessage("do it next", state: .queued)
        store.restoreQueuedPrompt("do it next")

        let userTexts = store.items.compactMap { item -> String? in
            if case .user(let m) = item { return m.text }
            return nil
        }
        #expect(userTexts == ["do it next"])
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
