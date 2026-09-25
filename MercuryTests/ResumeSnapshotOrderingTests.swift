import ChatCore
import Foundation
import MercuryKit
import Testing

/// Issue #109: a resume adopts its runtime as soon as `session.resume`
/// answers, so live events apply while the REST history page is still in
/// flight — and the resume snapshot (`running`, `inflight`, `open_requests`),
/// which predates them, used to be applied only AFTER that page, rewinding
/// newer live state. The snapshot must land before any event that arrived
/// after it. These tests hold the history page open, deliver newer events,
/// then release it.
@Suite("Resume snapshot ordering", .timeLimit(.minutes(1)))
@MainActor
struct ResumeSnapshotOrderingTests {
    /// Holds the history response until the test releases it.
    final class HistoryGate: @unchecked Sendable {
        private let released = DispatchSemaphore(value: 0)
        func release() { released.signal() }
        func wait() { _ = released.wait(timeout: .now() + 10) }
    }

    final class ResumeScript: @unchecked Sendable {
        let extras: [String: JSONValue]
        init(extras: [String: JSONValue]) { self.extras = extras }

        func respond(method: String) -> JSONValue? {
            let info: JSONValue = ["desktop_contract": 8]
            switch method {
            case "session.create":
                return ["session_id": "rt-probe", "info": info]
            case "session.resume":
                var result: [String: JSONValue] = [
                    "session_id": "rt-1", "stored_session_id": "stored-1", "info": info,
                ]
                for (key, value) in extras { result[key] = value }
                return .object(result)
            default:
                return .object([:])
            }
        }
    }

    private static let approvalID = "srq-aaaaaaaaaaa1"

    /// Fail initial hydration, then hold the first-page retry so the test
    /// observes the real controller while that request is still pending.
    final class FirstPageRetry: @unchecked Sendable {
        let reached = TestLatch()
        let gate = HistoryGate()
        private let lock = NSLock()
        private var queries: [String] = []
        var requestedQueries: [String] { lock.withLock { queries } }

        func respond(_ request: TestHTTPRequest) -> TestHTTPResponse {
            let count = lock.withLock {
                queries.append(request.query)
                return queries.count
            }
            if count == 1 { return TestHTTPResponse(500, "{}") }
            reached.signal()
            gate.wait()
            return TestHTTPResponse(200, #"{"messages":[{"id":1,"role":"user","content":"Earlier question"},{"id":2,"role":"assistant","content":"Recovered answer"}],"pagination":{"limit":100,"offset":0,"returned":2}}"#)
        }
    }

    /// Resume "stored-1" with its history page held, run `whileHeld` once the
    /// runtime is adopted, then release the page and let the resume finish.
    private func resume(
        extras: [String: JSONValue], historyStatus: Int = 200,
        whileHeld: (ChatController) -> Void
    ) async throws -> (ChatController, () -> Void) {
        let gate = HistoryGate()
        let script = ResumeScript(extras: extras)
        let server = try await HermesTestServer.start(
            rpc: { method, _ in script.respond(method: method) }
        ) { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": false}"#)
            case ("GET", let path) where path.hasPrefix("/api/sessions/stored-1/messages"):
                gate.wait()
                return TestHTTPResponse(historyStatus, #"{"messages": []}"#)
            default:
                return TestHTTPResponse(200, "{}")
            }
        }
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let model = AppModel(tokenStore: store)
        let cleanup = {
            gate.release()
            model.disconnect()
            server.stop()
            try? store.deleteToken(for: endpoint)
        }
        await model.connect(endpoint: endpoint, credentials: nil)
        let ready = await eventually {
            if case .ready = model.phase { return true }
            return false
        }
        try #require(ready)

        let chat = try #require(model.openChat(profile: nil))
        let summary = try #require(SessionSummary(json: ["id": "stored-1"]))
        let resuming = Task { await chat.begin(.resume(summary)) }
        let adopted = await eventually { chat.runtimeID == "rt-1" }
        try #require(adopted, "resume never adopted its runtime")

        whileHeld(chat)
        gate.release()
        await resuming.value
        return (chat, cleanup)
    }

    private func event(_ type: String, _ payload: JSONValue, seq: Int) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: "rt-1", payload: payload, seq: seq)
    }

    private func assistantBubbles(_ chat: ChatController) -> [AssistantMessage] {
        chat.store.items.compactMap { item in
            if case .assistant(let message) = item { return message }
            return nil
        }
    }

    /// Reopening a running chat can finish the resume RPC long before REST
    /// history. It must not look like an empty, idle conversation meanwhile.
    /// Keep the snapshot barrier, but expose a loading presentation to the UI.
    @Test(arguments: [200, 500])
    func slowHistoryHasAnExplicitLoadingPresentation(historyStatus: Int) async throws {
        let (chat, cleanup) = try await resume(
            extras: [
                "running": true,
                "inflight": ["user": "hi", "assistant": "Hel", "streaming": true],
            ], historyStatus: historyStatus
        ) { chat in
            #expect(chat.isLoading)
            #expect(chat.store.items.isEmpty)
            #expect(chat.loadingMessage == "Loading history…")
            chat.handle(event: event(GatewayEvent.Kind.messageDelta, ["text": "lo"], seq: 1))
            chat.handle(event: event(GatewayEvent.Kind.messageComplete, ["text": "Hello"], seq: 2))
            chat.handle(event: event(GatewayEvent.Kind.sessionInfo, ["running": false], seq: 3))
        }
        defer { cleanup() }

        #expect(chat.loadingMessage == nil)
        #expect((chat.historyError != nil) == (historyStatus == 500))
        #expect(!chat.isLoading)
        #expect(!chat.store.running)
        #expect(assistantBubbles(chat).map(\.text) == ["Hello"])
    }

    @Test func failedFirstPageRetryRestoresHistoryWithoutAnOpeningSpinner() async throws {
        let history = FirstPageRetry()
        let script = ResumeScript(extras: ["running": false])
        let server = try await HermesTestServer.start(
            rpc: { method, _ in script.respond(method: method) }
        ) { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": false}"#)
            case ("GET", "/api/sessions/stored-1/messages"):
                return history.respond(request)
            default:
                return TestHTTPResponse(200, "{}")
            }
        }
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let model = AppModel(tokenStore: store)
        defer {
            history.gate.release()
            model.disconnect()
            server.stop()
            try? store.deleteToken(for: endpoint)
        }
        await model.connect(endpoint: endpoint, credentials: nil)
        try #require(await eventually {
            if case .ready = model.phase { return true }
            return false
        })
        let chat = try #require(model.openChat(profile: nil))
        await chat.begin(.resume(try #require(SessionSummary(json: ["id": "stored-1"]))))
        try #require(chat.historyError != nil)
        #expect(chat.store.items.isEmpty)
        #expect(!chat.canLoadOlder)
        #expect(!chat.isLoading)

        let retrying = Task { await chat.retryHistory() }
        try #require(await history.reached.wait(), "first-page retry was never requested")
        #expect(chat.isLoading)
        #expect(chat.loadingMessage == nil, "retry must not insert the opening spinner row")
        #expect(chat.store.items.isEmpty)
        let queries = history.requestedQueries
        #expect(queries.count == 2)
        #expect(queries.allSatisfy { !$0.contains("offset=") }, "both requests must fetch the first page")

        history.gate.release()
        await retrying.value
        #expect(!chat.isLoading)
        #expect(chat.loadingMessage == nil)
        #expect(chat.historyError == nil)
        #expect(chat.store.items.count == 2)
        #expect(assistantBubbles(chat).map(\.text) == ["Recovered answer"])
        #expect(!chat.canLoadOlder)
    }

    /// The snapshot says a turn is running with an approval open; before
    /// the history page lands, the turn streams its last text, the approval
    /// is withdrawn, and the turn ends. The stale snapshot must not bring
    /// back the busy state or the withdrawn approval.
    @Test func aTurnThatEndsDuringHydrationStaysEnded() async throws {
        let (chat, cleanup) = try await resume(
            extras: [
                "running": true,
                "inflight": ["user": "hi", "assistant": "Hel", "streaming": true],
                "open_requests": [
                    [
                        "id": .string(Self.approvalID), "method": "approval",
                        "params": ["session_id": "rt-1", "request_id": "ap1", "command": "ls"],
                    ]
                ],
            ]
        ) { chat in
            chat.handle(event: event(GatewayEvent.Kind.messageDelta, ["text": "lo"], seq: 1))
            chat.handle(event: event(GatewayEvent.Kind.messageComplete, ["text": "Hello"], seq: 2))
            chat.handle(
                event: event(
                    GatewayEvent.Kind.requestCancel,
                    ["id": .string(Self.approvalID), "method": "approval", "reason": "resolved"],
                    seq: 3))
            chat.handle(event: event(GatewayEvent.Kind.sessionInfo, ["running": false], seq: 4))
        }
        defer { cleanup() }

        #expect(!chat.store.running, "the stale snapshot resurrected the busy state")
        #expect(chat.store.pendingApproval == nil, "the withdrawn approval came back")
        let bubbles = assistantBubbles(chat)
        #expect(bubbles.map(\.text) == ["Hello"])
        #expect(bubbles.allSatisfy { !$0.isStreaming })
    }

    /// The mirror case: the snapshot says idle, and a new turn starts
    /// before the history page lands. The stale idle flag must not end it.
    @Test func aTurnThatStartsDuringHydrationKeepsRunning() async throws {
        let (chat, cleanup) = try await resume(extras: ["running": false]) { chat in
            chat.handle(event: event(GatewayEvent.Kind.messageStart, [:], seq: 1))
            chat.handle(event: event(GatewayEvent.Kind.messageDelta, ["text": "Hi"], seq: 2))
        }
        defer { cleanup() }

        #expect(chat.store.running, "the stale idle snapshot ended a live turn")
        let streamed = await eventually { assistantBubbles(chat).last?.text == "Hi" }
        #expect(streamed, "bubbles: \(assistantBubbles(chat).map(\.text))")
        #expect(assistantBubbles(chat).last?.isStreaming == true)
    }
}
