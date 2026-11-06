import ChatCore
import Foundation
import MercuryKit
import Testing

/// Chat on a session authority (hermes v0.23 gateway listener, e.g. the
/// Webapp): sends carry a stable submission id and bind to their admission,
/// the shared queue drives the composer's queue panel, event-raised
/// approvals are answered by `prompt_id`, and the queue's Edit and Remove
/// reach the owner. The wire shapes are MercuryKit's (AuthorityQueueTests).
@Suite("Chat on a session authority", .timeLimit(.minutes(1)))
@MainActor
struct AuthorityChatTests {
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String: TestRPCReply] = [:]

        func set(_ method: String, _ reply: TestRPCReply) {
            lock.withLock { replies[method] = reply }
        }

        func reply(_ method: String) -> TestRPCReply? {
            if method == "session.create" {
                return .result([
                    "session_id": "local-abc", "stored_session_id": "local-abc", "messages": [],
                    "running": false, "authority_epoch": 1, "replay_epoch": "ep", "last_sequence": 0,
                    "subscription_id": "sub-1", "revision": 3, "execution_generation": 2,
                    "pending": [], "prompts": [], "info": ["desktop_protocol": "hermes-gateway-v1"],
                ])
            }
            return lock.withLock { replies[method] }
        }
    }

    private func openChat(_ script: Script) async throws
        -> (ChatController, HermesTestServer, () -> Void)
    {
        let server = try await HermesTestServer.start(
            rpcReply: { method, _ in script.reply(method) }
        ) { request in
            request.path == "/api/status"
                ? TestHTTPResponse(200, #"{"auth_required": false}"#)
                : TestHTTPResponse(200, #"{"messages": []}"#)
        }
        server.sessionAuthority = true
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let model = AppModel(tokenStore: store)
        await model.connect(endpoint: endpoint, credentials: nil)
        let ready = await eventually {
            if case .ready = model.phase { return true }
            return false
        }
        try #require(ready)
        let chat = try #require(model.openChat(profile: nil))
        await chat.begin(.create(cwd: nil, title: nil))
        try #require(chat.runtimeID == "local-abc")
        return (
            chat, server,
            {
                model.disconnect()
                server.stop()
                try? store.deleteToken(for: endpoint)
            }
        )
    }

    private func requests(_ server: HermesTestServer, _ method: String) -> [TestRPCRequest] {
        server.rpcRequests.filter { $0.method == method }
    }

    private func users(_ chat: ChatController) -> [UserMessage] {
        chat.store.items.compactMap { item in
            if case .user(let message) = item { return message }
            return nil
        }
    }

    private func pushQueue(_ server: HermesTestServer, _ rows: [JSONValue]) {
        server.pushEvent(
            "session.info", sessionID: "local-abc",
            payload: ["revision": 3, "execution_generation": 2, "running": true, "pending": .array(rows)])
    }

    @Test func aSendBindsToItsAdmissionAndWaitsInTheQueue() async throws {
        let script = Script()
        script.set("prompt.submit", .result(["status": "queued", "admission_id": "a1", "sequence": 1]))
        let (chat, server, cleanup) = try await openChat(script)
        defer { cleanup() }

        await chat.submit("later please")

        let sent = try #require(requests(server, "prompt.submit").last)
        #expect(sent.params["submission_id"]?.stringValue?.isEmpty == false)
        #expect(sent.params["source"] == nil)
        #expect(chat.hasSharedQueue)
        let echo = try #require(users(chat).first)
        #expect(chat.store.admissionID(forEcho: echo.id) == "a1")

        pushQueue(server, [["admission_id": "a1", "sequence": 1, "status": "queued", "text": "later please", "controls": ["steer", "replace"]]])
        #expect(await eventually { chat.store.waitingRow(forEcho: echo.id) != nil })
    }

    @Test func aRetryReusesTheSubmissionID() async throws {
        let script = Script()
        script.set("prompt.submit", .error(code: 5000, message: "lost"))
        let (chat, server, cleanup) = try await openChat(script)
        defer { cleanup() }

        await chat.submit("hello")
        let echo = try #require(users(chat).first)
        script.set("prompt.submit", .result(["status": "queued", "admission_id": "a1"]))
        await chat.retrySend(messageID: echo.id)

        let ids = requests(server, "prompt.submit").compactMap { $0.params["submission_id"]?.stringValue }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 1)
    }

    @Test func anEventApprovalIsAnsweredByPromptID() async throws {
        let script = Script()
        script.set("approval.respond", .result(["status": "resolved"]))
        let (chat, server, cleanup) = try await openChat(script)
        defer { cleanup() }

        server.pushEvent(
            "approval.request", sessionID: "local-abc",
            payload: ["prompt_id": "p1", "execution_generation": 2, "command": "rm x", "choices": ["once", "deny"]])
        let approval = try #require(
            await eventuallyValue { chat.store.pendingApproval })
        #expect(await chat.respondApproval(approval, choice: "deny"))

        let sent = try #require(requests(server, "approval.respond").last)
        #expect(sent.params == ["session_id": "local-abc", "execution_generation": 2, "prompt_id": "p1", "choice": "deny"])
        #expect(requests(server, "request.answer").isEmpty)
        #expect(chat.store.pendingApproval == nil)
    }

    @Test func editAndRemoveReachTheOwner() async throws {
        let script = Script()
        script.set("prompt.submit", .result(["status": "queued", "admission_id": "a1"]))
        script.set("prompt.replace_queued", .result(["admission_id": "a2", "status": "queued"]))
        script.set("prompt.cancel", .result(["admission_id": "a2", "status": "terminal", "outcome": "cancelled"]))
        let (chat, server, cleanup) = try await openChat(script)
        defer { cleanup() }

        await chat.submit("draft")
        let echo = try #require(users(chat).first)
        pushQueue(server, [["admission_id": "a1", "sequence": 1, "status": "queued", "text": "draft", "controls": ["replace"]]])
        let row = try #require(await eventuallyValue { chat.store.queue.first })

        #expect(await chat.editQueued(row, text: "final") == nil)
        let replaced = try #require(requests(server, "prompt.replace_queued").last)
        #expect(replaced.params["admission_id"] == "a1")
        #expect(replaced.params["text"] == "final")
        #expect(users(chat).first?.text == "final")
        #expect(chat.store.admissionID(forEcho: echo.id) == "a2")

        pushQueue(server, [["admission_id": "a2", "sequence": 2, "status": "queued", "text": "final", "controls": ["replace"]]])
        let edited = try #require(await eventuallyValue { chat.store.queue.first { $0.admissionID == "a2" } })
        await chat.removeQueued(edited)
        #expect(requests(server, "prompt.cancel").last?.params == ["session_id": "local-abc", "admission_id": "a2"])
        server.pushEvent(
            "message.complete", sessionID: "local-abc",
            payload: ["admission_id": "a2", "outcome": "cancelled", "status": "complete"])
        #expect(await eventually { users(chat).isEmpty })
    }

    /// Poll until `body` yields a value (main-actor state fed by the event pump).
    private func eventuallyValue<T>(_ body: @MainActor () -> T?) async -> T? {
        for _ in 0..<100 {
            if let value = body() { return value }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}
