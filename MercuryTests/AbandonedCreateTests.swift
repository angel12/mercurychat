import Foundation
import MercuryKit
import Testing

/// Issue #111: closing a chat while its `session.create` is still in flight
/// invalidates the controller, and teardown finds no runtime to close yet.
/// The create then succeeds, fails the begin-generation guard, and its
/// freshly minted runtime was dropped unclosed — leaked server-side for as
/// long as the connection stayed open. A superseded create has no other
/// owner, so it must relinquish its own runtime. A superseded RESUME must
/// not: it can alias a runtime a successor also holds (#60).
@Suite("Abandoned session creation", .timeLimit(.minutes(1)))
@MainActor
struct AbandonedCreateTests {
    /// Titles that mark the chat's own creates — AppModel's connect-time
    /// contract probe also creates (and closes) an untitled throwaway session.
    nonisolated static let chatTitle = "Abandoned chat"

    final class Script: @unchecked Sendable {
        func respond(method: String, params: JSONValue) -> JSONValue? {
            switch method {
            case "session.list":
                // No canonical Bot Chat: the `.bot` path mints one.
                return .object(["sessions": .array([])])
            case "session.create":
                switch params["title"]?.stringValue {
                case AbandonedCreateTests.chatTitle:
                    return .object(["session_id": .string("rt-created")])
                case "Bot Chat":
                    return .object(["session_id": .string("rt-bot")])
                default:
                    return .object(["session_id": .string("rt-probe")])
                }
            case "session.resume":
                return .object([
                    "session_id": .string("rt-resumed"),
                    "stored_session_id": .string("stored-1"),
                ])
            case "session.close":
                return .object(["closed": .bool(true)])
            default:
                return .object([:])
            }
        }
    }

    private func connectedModel(
        hold: @escaping @Sendable (String, JSONValue) -> TestReplyGate?
    ) async throws -> (AppModel, HermesTestServer, () -> Void) {
        let script = Script()
        let server = try await HermesTestServer.start(
            rpc: { method, params in script.respond(method: method, params: params) },
            rpcHold: hold
        ) { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": false}"#)
            default:
                return TestHTTPResponse(200, #"{"messages": []}"#)
            }
        }
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let model = AppModel(tokenStore: store)
        await model.connect(endpoint: endpoint, credentials: nil)
        let ready = await eventually {
            if case .ready = model.phase { return true }
            return false
        }
        try #require(ready)
        return (
            model, server,
            {
                model.disconnect()
                server.stop()
                try? store.deleteToken(for: endpoint)
            }
        )
    }

    private func closes(_ server: HermesTestServer, _ runtimeID: String) -> Int {
        server.rpcRequests.filter {
            $0.method == "session.close" && $0.params["session_id"]?.stringValue == runtimeID
        }.count
    }

    /// Open a chat, start `mode`, close the chat while the gated RPC is in
    /// flight, then let the RPC succeed.
    private func abandon(
        _ mode: ChatController.Mode, gate: TestReplyGate, model: AppModel
    ) async throws -> ChatController {
        let chat = try #require(model.openChat(profile: nil))
        let beginning = Task { await chat.begin(mode) }
        #expect(await gate.reached.wait(), "the gated RPC never arrived")
        model.closeChat(chat)
        gate.open()
        await beginning.value
        return chat
    }

    @Test func anAbandonedCreateClosesItsRuntime() async throws {
        let gate = TestReplyGate()
        let (model, server, cleanup) = try await connectedModel { method, params in
            method == "session.create" && params["title"]?.stringValue == Self.chatTitle
                ? gate : nil
        }
        defer {
            gate.open()
            cleanup()
        }

        let chat = try await abandon(
            .create(cwd: nil, title: Self.chatTitle), gate: gate, model: model)

        let closed = await eventually(within: 3) { closes(server, "rt-created") == 1 }
        #expect(closed, "the abandoned create's runtime was never closed")
        #expect(chat.runtimeID == nil)
    }

    @Test func anAbandonedBotChatCreateClosesItsRuntime() async throws {
        let gate = TestReplyGate()
        let (model, server, cleanup) = try await connectedModel { method, params in
            method == "session.create" && params["title"]?.stringValue == "Bot Chat"
                ? gate : nil
        }
        defer {
            gate.open()
            cleanup()
        }

        let chat = try await abandon(
            .bot(profile: "helper", expectCanonical: false), gate: gate, model: model)

        let closed = await eventually(within: 3) { closes(server, "rt-bot") == 1 }
        #expect(closed, "the abandoned Bot Chat mint's runtime was never closed")
        #expect(chat.runtimeID == nil)
    }

    @Test func anAbandonedResumeDoesNotCloseItsRuntime() async throws {
        let gate = TestReplyGate()
        let (model, server, cleanup) = try await connectedModel { method, _ in
            method == "session.resume" ? gate : nil
        }
        defer {
            gate.open()
            cleanup()
        }

        let session = try #require(
            SessionSummary(json: .object(["session_id": .string("stored-1")])))
        let chat = try await abandon(.resume(session), gate: gate, model: model)

        // A resume can alias a runtime a successor also holds (#60) — the
        // superseded one must leave it alone. Give a stray close time to land.
        try await Task.sleep(for: .milliseconds(500))
        #expect(closes(server, "rt-resumed") == 0)
        #expect(chat.runtimeID == nil)
    }
}
