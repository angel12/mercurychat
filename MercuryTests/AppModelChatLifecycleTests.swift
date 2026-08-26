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
}
