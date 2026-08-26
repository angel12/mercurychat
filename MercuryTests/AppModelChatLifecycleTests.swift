import Foundation
import MercuryKit
import Testing

/// Issue #48: `openChat` force-unwrapped the connection, but its sole caller
/// is a `.task` body — which runs on a later MainActor hop (and still runs
/// when the task is already cancelled), so a `disconnect()` can nil the
/// connection first. Notably the auth-expired pump branch disconnects with no
/// user action at all: open a session at the wrong moment and the app dies.
@Suite("AppModel chat lifecycle", .timeLimit(.minutes(1)))
@MainActor
struct AppModelChatLifecycleTests {
    @Test func openChatWithoutConnectionReturnsNil() {
        let model = AppModel(
            tokenStore: KeychainTokenStore(service: "com.mercury.tokens.tests"))
        let chat: ChatController? = model.openChat(profile: nil)
        #expect(chat == nil)
        #expect(model.activeChat == nil)
    }

    @Test func disconnectClearsActiveChat() async throws {
        // An open, ungated server: the probe passes and connect() installs
        // the connection, which is all openChat needs.
        let server = try await HermesTestServer.start { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": false}"#)
            default:
                return TestHTTPResponse(200)
            }
        }
        defer { server.stop() }

        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        // Isolated keychain service — fixtures never touch the real
        // `com.mercury.tokens` items. (No credentials are passed below, so
        // nothing is ever persisted; the store is only injection hygiene.)
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        defer { store.deleteToken(for: endpoint) }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        await model.connect(endpoint: endpoint, credentials: nil)

        let chat = model.openChat(profile: nil)
        #expect(chat != nil)
        #expect(model.activeChat === chat)

        // disconnect() must drop the registration too — a stale activeChat
        // would keep routing the next connection's events into a dead chat.
        model.disconnect()
        #expect(model.activeChat == nil)
    }

    // MARK: begin() racing a disconnect (#48 follow-up)

    // openChat can succeed and disconnect() land before ChatView's `.task`
    // reaches `begin(mode)` — the controller then holds a stopped (or
    // stopping) connection. begin must not dial RPCs for a chat the app
    // already discarded: depending on timing it would surface a spurious
    // "Not connected" error, or worse, the RPC still wins the race against
    // the async connection.stop() and creates/resumes a server-side runtime
    // session that nothing ever tears down (activeChat is nil, so closeChat's
    // identity guard skips teardown).

    @Test func beginCreateAfterDisconnectIsInert() async throws {
        let (model, chat, cleanup) = try await openedChat()
        defer { cleanup() }

        model.disconnect()
        await chat.begin(.create(cwd: nil, title: nil))

        #expect(chat.errorMessage == nil)
        #expect(chat.isLoading == false)
        #expect(chat.runtimeID == nil)
    }

    @Test func beginResumeAfterDisconnectIsInert() async throws {
        let (model, chat, cleanup) = try await openedChat()
        defer { cleanup() }

        let session = try #require(
            SessionSummary(json: .object(["session_id": .string("stored-1")])))
        model.disconnect()
        await chat.begin(.resume(session))

        #expect(chat.errorMessage == nil)
        #expect(chat.historyError == nil)
        #expect(chat.runtimeID == nil)
    }

    @Test func beginAfterCloseChatIsInert() async throws {
        let (model, chat, cleanup) = try await openedChat()
        defer { cleanup() }

        // The same race exists on plain navigation: onDisappear's closeChat
        // can land while the `.task` body is still on its way to begin().
        model.closeChat(chat)
        await chat.begin(.create(cwd: nil, title: nil))

        #expect(chat.errorMessage == nil)
        #expect(chat.runtimeID == nil)
        model.disconnect()
    }

    /// Connect to a scripted open server and open a chat — the shared setup
    /// of every begin-vs-teardown race test. The returned cleanup stops the
    /// server and disconnects (both idempotent).
    private func openedChat() async throws -> (AppModel, ChatController, () -> Void) {
        let server = try await HermesTestServer.start { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": false}"#)
            default:
                return TestHTTPResponse(200)
            }
        }
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let model = AppModel(tokenStore: store)
        await model.connect(endpoint: endpoint, credentials: nil)
        let chat = try #require(model.openChat(profile: nil))
        return (
            model, chat,
            {
                model.disconnect()
                server.stop()
                store.deleteToken(for: endpoint)
            }
        )
    }
}
