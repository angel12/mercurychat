import Foundation
import MercuryKit
import Testing

/// Issue #108: the OAuth browser sign-in form (`pendingOAuthLogin`) belongs to
/// the server that presented it. Recent servers stay tappable while it shows,
/// and a connect to another server must drop it — otherwise A's form sits
/// next to B's error (the form names only the provider, not the host), or
/// hides while B is connected and resurfaces on the next disconnect.
@Suite("AppModel OAuth form replacement", .timeLimit(.minutes(1)))
@MainActor
struct AppModelOAuthFormTests {
    /// A gated, OAuth-only server that advertises the native PKCE flow.
    private static func startOAuthOnlyServer() async throws -> HermesTestServer {
        try await HermesTestServer.start { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(
                    200, #"{"auth_required": true, "auth_flows": ["cookie", "native_pkce"]}"#)
            case ("GET", "/api/auth/providers"):
                return TestHTTPResponse(
                    200,
                    #"{"providers": [{"name": "github", "display_name": "GitHub", "supports_password": false}]}"#
                )
            default:
                return TestHTTPResponse(401)
            }
        }
    }

    private static func withDefaultsRestored(
        _ body: () async throws -> Void
    ) async rethrows {
        let prior = ["lastServer", "savedServers"].map {
            ($0, UserDefaults.standard.object(forKey: $0))
        }
        defer {
            for (key, value) in prior {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        try await body()
    }

    @Test func aFailedConnectToAnotherServerDropsTheOAuthForm() async throws {
        let serverA = try await Self.startOAuthOnlyServer()
        defer { serverA.stop() }
        let serverB = try await HermesTestServer.start { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(500)
            default:
                return TestHTTPResponse(404)
            }
        }
        defer { serverB.stop() }

        let endpointA = try ServerEndpoint.parse("http://127.0.0.1:\(serverA.port)").endpoint
        let endpointB = try ServerEndpoint.parse("http://127.0.0.1:\(serverB.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        defer { for endpoint in [endpointA, endpointB] { try? store.deleteToken(for: endpoint) } }

        try await Self.withDefaultsRestored {
            let model = AppModel(tokenStore: store)
            defer { model.disconnect() }

            await model.connect(endpoint: endpointA, credentials: nil)
            #expect(model.pendingOAuthLogin?.endpoint == endpointA, "A never offered OAuth sign-in")
            #expect(model.pendingOAuthLogin?.providerName == "github")

            // The user taps B under Recent servers instead; B fails.
            await model.connect(endpoint: endpointB, credentials: .sessionToken("synthetic-b"))
            #expect(model.connectError != nil, "B's failure never surfaced")
            #expect(model.pendingOAuthLogin == nil, "A's OAuth form stayed next to B's error")
        }
    }

    @Test func anOAuthFormDoesNotResurfaceAfterAnotherServerConnects() async throws {
        let serverA = try await Self.startOAuthOnlyServer()
        defer { serverA.stop() }
        let serverB = try await HermesTestServer.start { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": false}"#)
            default:
                return TestHTTPResponse(200, "{}")
            }
        }
        defer { serverB.stop() }

        let endpointA = try ServerEndpoint.parse("http://127.0.0.1:\(serverA.port)").endpoint
        let endpointB = try ServerEndpoint.parse("http://127.0.0.1:\(serverB.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        defer { for endpoint in [endpointA, endpointB] { try? store.deleteToken(for: endpoint) } }

        try await Self.withDefaultsRestored {
            let model = AppModel(tokenStore: store)
            defer { model.disconnect() }

            await model.connect(endpoint: endpointA, credentials: nil)
            #expect(model.pendingOAuthLogin?.endpoint == endpointA, "A never offered OAuth sign-in")

            await model.connect(endpoint: endpointB, credentials: .sessionToken("synthetic-b"))
            let readyOnB = await eventually { model.phase == .ready(isReconnect: false) }
            #expect(readyOnB, "B never reached ready (phase: \(model.phase))")

            // Leaving B returns to the connect screen: A's form must not be
            // waiting there.
            model.disconnect()
            #expect(model.pendingOAuthLogin == nil, "A's OAuth form came back after leaving B")
        }
    }

    /// The flip side: auth expiry on the current OAuth-only server presents
    /// the browser sign-in and THEN disconnects (#50), so the reset must stay
    /// in connect() — clearing in disconnect() would strand the user.
    @Test func authExpiryOnAnOAuthServerKeepsTheBrowserSignIn() async throws {
        let server = try await HermesTestServer.start { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(
                    200, #"{"auth_required": true, "auth_flows": ["cookie", "native_pkce"]}"#)
            case ("GET", "/api/profiles/active"):
                return TestHTTPResponse(200, "{}")
            case ("GET", "/api/auth/providers"):
                return TestHTTPResponse(
                    200,
                    #"{"providers": [{"name": "github", "display_name": "GitHub", "supports_password": false}]}"#
                )
            default:
                // The socket upgrade is refused: the bearer was revoked after
                // the REST probe passed.
                return TestHTTPResponse(401)
            }
        }
        defer { server.stop() }

        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        defer { try? store.deleteToken(for: endpoint) }

        try await Self.withDefaultsRestored {
            let model = AppModel(tokenStore: store)
            defer { model.disconnect() }
            await model.connect(
                endpoint: endpoint,
                credentials: .password(
                    PasswordSession(
                        provider: "github", username: "",
                        accessToken: "dead-at", refreshToken: "dead-rt", expiresAt: 0)))

            let presented = await eventually { model.pendingOAuthLogin != nil }
            #expect(presented, "browser sign-in was never re-presented (phase: \(model.phase))")
            #expect(model.pendingOAuthLogin?.endpoint == endpoint)
            #expect(model.connection == nil)
        }
    }
}
