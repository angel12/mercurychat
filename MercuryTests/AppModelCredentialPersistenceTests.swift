import Foundation
import MercuryKit
import Testing

/// Issue #37: opening the app with a lapsed access token silently refreshes
/// during the connect probe — rotating BOTH tokens server-side — but the
/// ready-time persist then wrote the PRE-rotation pair back to the keychain.
/// The next launch replayed the dead refresh token; Nous reuse-detection
/// revokes the whole session on replay, forcing a fresh browser sign-in
/// almost every launch.
@Suite("AppModel credential persistence", .timeLimit(.minutes(1)))
@MainActor
struct AppModelCredentialPersistenceTests {
    @Test func readyPersistsRotatedTokensNotTheStalePair() async throws {
        // A gated server where the stored access token has lapsed: validation
        // 401s, the refresh rotates to a fresh pair, and everything after
        // authenticates only with the fresh access token.
        let server = try await HermesTestServer.start { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": true}"#)
            case ("GET", "/api/profiles/active"):
                guard request.headers["authorization"] == "Bearer fresh-at" else {
                    return TestHTTPResponse(401)
                }
                return TestHTTPResponse(200, "{}")
            case ("POST", "/auth/native/refresh"):
                let body = try? JSONDecoder().decode(JSONValue.self, from: request.body)
                guard body?["refresh_token"]?.stringValue == "stale-rt" else {
                    // A replayed (already-rotated) refresh token is exactly
                    // the Nous failure mode — reject it like the portal does.
                    return TestHTTPResponse(401)
                }
                return TestHTTPResponse(
                    200,
                    #"{"access_token": "fresh-at", "refresh_token": "fresh-rt", "expires_at": 99}"#
                )
            case ("POST", "/api/auth/ws-ticket"):
                guard request.headers["authorization"] == "Bearer fresh-at" else {
                    return TestHTTPResponse(401)
                }
                return TestHTTPResponse(200, #"{"ticket": "tik-1"}"#)
            default:
                return TestHTTPResponse(404)
            }
        }
        defer { server.stop() }

        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore()
        defer {
            store.deleteToken(for: endpoint)
            UserDefaults.standard.removeObject(forKey: "lastServer")
            UserDefaults.standard.removeObject(forKey: "savedServers")
        }

        let model = AppModel()
        defer { model.disconnect() }
        await model.connect(
            endpoint: endpoint,
            credentials: .password(
                PasswordSession(
                    provider: "nous", username: "spencer",
                    accessToken: "stale-at", refreshToken: "stale-rt", expiresAt: 0)))

        let becameReady = await eventually { model.phase == .ready(isReconnect: false) }
        #expect(becameReady, "connection never reached ready: \(model.phase)")

        // The pump's ready-time persist runs before the phase is observable,
        // so the keychain verdict is already final here. It must hold the
        // ROTATED pair — persisting the stale one strands next launch on a
        // refresh token the server has already burned.
        guard case .password(let saved)? = store.credentials(for: endpoint) else {
            Issue.record("no password credentials were persisted")
            return
        }
        #expect(saved.accessToken == "fresh-at")
        #expect(saved.refreshToken == "fresh-rt")
    }

    /// Poll until the condition holds (socket callbacks land on background
    /// queues).
    private func eventually(
        _ condition: @MainActor () -> Bool, within seconds: TimeInterval = 10
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
