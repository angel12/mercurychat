import Foundation
import MercuryKit
import Testing

/// Issue #50: when the gateway gives up with `.authExpired` the pump forks on
/// `serverStatus?.authRequired` — a gated server re-presents sign-in, a token
/// server asks for a fresh dashboard URL — and both must present BEFORE the
/// `disconnect()` that follows, because disconnect cancels the very pump task
/// running this branch. Present after, and the user is dropped to a bare
/// disconnected screen with no way back in.
///
/// Both arms drive a real socket: the server refuses the WebSocket upgrade
/// with 401, which `GatewayClient` maps onto the "(4401)" credential
/// rejection — the signal that stops the redial loop instead of retrying.
@Suite("AppModel auth expiry", .timeLimit(.minutes(1)))
@MainActor
struct AppModelAuthExpiredTests {
    @Test func aGatedServerRepresentsSignIn() async throws {
        let server = try await HermesTestServer.start { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": true}"#)
            case ("GET", "/api/profiles/active"):
                return TestHTTPResponse(200, "{}")
            case ("GET", "/api/auth/providers"):
                return TestHTTPResponse(
                    200,
                    #"{"providers": [{"name": "basic", "display_name": "Password", "supports_password": true}]}"#
                )
            default:
                // Everything else — the socket upgrade included — is refused:
                // the server revoked these credentials after the REST probe
                // passed.
                return TestHTTPResponse(401)
            }
        }
        defer { server.stop() }

        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        defer { store.deleteToken(for: endpoint) }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        await model.connect(
            endpoint: endpoint,
            credentials: .password(
                PasswordSession(
                    provider: "basic", username: "spencer",
                    accessToken: "dead-at", refreshToken: "dead-rt", expiresAt: 0)))

        let presented = await eventually { model.pendingPasswordLogin != nil }
        #expect(presented, "gated sign-in was never re-presented (phase: \(model.phase))")
        #expect(model.pendingPasswordLogin?.providerName == "basic")
        #expect(model.connectError == HermesError.sessionExpired.errorDescription)
        // Presented first, then torn down — not the other way round.
        #expect(model.connection == nil)
    }

    @Test func aTokenServerAsksForAFreshDashboardURL() async throws {
        let server = try await HermesTestServer.start { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": false}"#)
            case ("GET", "/api/profiles/active"):
                return TestHTTPResponse(200, "{}")
            default:
                return TestHTTPResponse(401)
            }
        }
        defer { server.stop() }

        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        defer { store.deleteToken(for: endpoint) }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        await model.connect(endpoint: endpoint, credentials: .sessionToken("dead-token"))

        let surfaced = await eventually { model.connectError != nil }
        #expect(surfaced, "no error ever surfaced (phase: \(model.phase))")
        // An ephemeral token that died with a backend restart: there is no
        // sign-in form to show, so the banner must say where a fresh one
        // comes from rather than offering a password box.
        #expect(model.connectError == HermesError.unauthorized.errorDescription)
        #expect(model.pendingPasswordLogin == nil)
        #expect(model.connection == nil)
    }
}
