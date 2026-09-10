import Foundation
import MercuryKit
import Testing

/// PR #78 review findings: the canonical Bot Chat must be resolved at open
/// time by the registry lookup (never a cached roster row), compact commands
/// must run REAL compression (`session.compress`, not a `prompt.submit` with
/// slash text), and nothing may rewrite the canonical title.
@Suite("Canonical Bot Chat controller", .timeLimit(.minutes(1)))
@MainActor
struct BotChatControllerTests {
    /// Scripted RPC state shared with the fake gateway. `@unchecked` because
    /// access is guarded by the lock.
    final class GatewayScript: @unchecked Sendable {
        private let lock = NSLock()
        private var canonicalExists = false

        func setCanonicalExists(_ exists: Bool) {
            lock.withLock { canonicalExists = exists }
        }

        func respond(method: String, params: JSONValue) -> JSONValue? {
            switch method {
            case "session.list":
                let exists = lock.withLock { canonicalExists }
                guard exists else { return .object(["sessions": .array([])]) }
                return .object([
                    "sessions": .array([
                        .object([
                            "id": .string("stored-canonical"),
                            "resolved_id": .string("stored-canonical"),
                            "title": .string("Bot Chat"),
                            "message_count": .number(3),
                        ])
                    ])
                ])
            case "session.create":
                // AppModel's connect-time contract probe also creates (and
                // closes) a throwaway session — only a create carrying the
                // canonical title is the Bot Chat mint, and only that one
                // becomes findable for later lookups.
                guard params["title"]?.stringValue == "Bot Chat" else {
                    return .object(["session_id": .string("rt-probe")])
                }
                lock.withLock { canonicalExists = true }
                return .object(["session_id": .string("rt-created")])
            case "session.resume":
                return .object([
                    "session_id": .string("rt-resumed"),
                    "stored_session_id": .string("stored-canonical"),
                ])
            case "session.compress":
                return .object(["status": .string("pending")])
            default:
                return .object([:])
            }
        }
    }

    private func connectedModel(
        _ script: GatewayScript
    ) async throws -> (AppModel, HermesTestServer, () -> Void) {
        let server = try await HermesTestServer.start(
            rpc: { method, params in script.respond(method: method, params: params) }
        ) { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": false}"#)
            default:
                // Transcript hydration and friends: an empty page is fine —
                // begin() tolerates hydration failure independently.
                return TestHTTPResponse(200, #"{"messages": []}"#)
            }
        }
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let model = AppModel(tokenStore: store)
        await model.connect(endpoint: endpoint, credentials: nil)
        let ready = await eventually { model.isConnected }
        try #require(ready)
        return (
            model, server,
            {
                model.disconnect()
                server.stop()
                store.deleteToken(for: endpoint)
            }
        )
    }

    private func rpcMethods(_ server: HermesTestServer) -> [String] {
        server.rpcRequests.map(\.method)
    }

    /// The session.create calls that mint a canonical Bot Chat — filtered by
    /// title because AppModel's contract probe creates throwaway sessions of
    /// its own on connect.
    private func canonicalCreates(_ server: HermesTestServer) -> [TestRPCRequest] {
        server.rpcRequests.filter {
            $0.method == "session.create"
                && $0.params["title"]?.stringValue == "Bot Chat"
        }
    }

    @Test func compactCommandRunsCompressionNotPromptSubmit() async throws {
        let script = GatewayScript()
        script.setCanonicalExists(true)
        let (model, server, cleanup) = try await connectedModel(script)
        defer { cleanup() }

        let chat = try #require(model.openChat(profile: "researcher"))
        chat.isCanonicalBotChat = true
        await chat.begin(.bot(profile: "researcher", expectCanonical: true))
        #expect(chat.runtimeID == "rt-resumed")

        await chat.submit("/new")

        let methods = rpcMethods(server)
        #expect(methods.contains("session.compress"))
        #expect(!methods.contains("prompt.submit"))
    }

    @Test func staleRosterReopenResolvesInsteadOfDuplicating() async throws {
        // The reviewed race: the roster row said "no canonical chat" (nil
        // stored id), one was created, and a reopen while the roster is still
        // stale must FIND it — not mint a twin.
        let script = GatewayScript()
        let (model, server, cleanup) = try await connectedModel(script)
        defer { cleanup() }

        // First open: confirmed absence → create, titled "Bot Chat".
        let first = try #require(model.openChat(profile: "researcher"))
        await first.begin(.bot(profile: "researcher", expectCanonical: false))
        #expect(first.runtimeID == "rt-created")
        let creates = canonicalCreates(server)
        #expect(creates.count == 1)
        #expect(creates.first?.params["profile"]?.stringValue == "researcher")
        model.closeChat(first)

        // Reopen with the SAME stale expectation (roster never refreshed):
        // the open-time lookup finds the chat and resumes it.
        let second = try #require(model.openChat(profile: "researcher"))
        await second.begin(.bot(profile: "researcher", expectCanonical: false))
        #expect(second.runtimeID == "rt-resumed")

        #expect(canonicalCreates(server).count == 1)
        #expect(rpcMethods(server).contains("session.resume"))
    }

    @Test func emptyLookupAgainstRosterSightingFailsClosed() async throws {
        // The roster saw a canonical chat, but the registry lookup answers
        // empty (profile backend mid-restart). Creating here would fork the
        // forever-chat — the open must fail with a retryable error instead.
        let script = GatewayScript()  // canonicalExists = false → empty lookups
        let (model, server, cleanup) = try await connectedModel(script)
        defer { cleanup() }

        let chat = try #require(model.openChat(profile: "researcher"))
        await chat.begin(.bot(profile: "researcher", expectCanonical: true))

        #expect(chat.errorMessage != nil)
        #expect(chat.runtimeID == nil)
        #expect(canonicalCreates(server).isEmpty)
    }

    @Test func canonicalRenameIsRefusedBeforeTheWire() async throws {
        let script = GatewayScript()
        script.setCanonicalExists(true)
        let (model, server, cleanup) = try await connectedModel(script)
        defer { cleanup() }

        let chat = try #require(model.openChat(profile: "researcher"))
        chat.isCanonicalBotChat = true
        await chat.begin(.bot(profile: "researcher", expectCanonical: true))

        await chat.rename("Notes")

        #expect(!rpcMethods(server).contains("session.title"))
    }
}
