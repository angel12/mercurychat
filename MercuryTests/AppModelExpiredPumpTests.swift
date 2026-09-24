import Foundation
import MercuryKit
import Testing

/// Issue #90: when a gated connection's credentials expire, its update pump
/// looks up the server's sign-in providers and then tears the connection
/// down. That branch suspends on the lookup, and connecting to another
/// server while it is suspended cancels the pump — but the cancelled lookup
/// swallowed its error, and the branch resumed to present A's sign-in and
/// call `disconnect()`, which killed the replacement connection to B.
@Suite("AppModel expired pump", .timeLimit(.minutes(1)))
@MainActor
struct AppModelExpiredPumpTests {
    /// Holds A's provider lookup until the test releases it.
    final class ProviderHold: @unchecked Sendable {
        let reached = TestLatch()
        private let released = DispatchSemaphore(value: 0)
        func release() { released.signal() }
        func wait() {
            reached.signal()
            _ = released.wait(timeout: .now() + 10)
        }
    }

    /// A's lookup finally answering with a password provider, or failing.
    @Test(arguments: [true, false])
    func anExpiredPumpCannotTearDownAReplacementConnection(lookupSucceeds: Bool) async throws {
        let hold = ProviderHold()
        let serverA = try await HermesTestServer.start { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": true}"#)
            case ("GET", "/api/profiles/active"):
                return TestHTTPResponse(200, "{}")
            case ("GET", "/api/auth/providers"):
                hold.wait()
                return lookupSucceeds
                    ? TestHTTPResponse(
                        200,
                        #"{"providers": [{"name": "basic", "display_name": "Password", "supports_password": true}]}"#)
                    : TestHTTPResponse(500)
            default:
                // The socket upgrade is refused: A's credentials were revoked
                // after the REST probe passed, so its gateway reports expiry.
                return TestHTTPResponse(401)
            }
        }
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
        let priorDefaults = ["lastServer", "savedServers"].map {
            ($0, UserDefaults.standard.object(forKey: $0))
        }
        defer {
            hold.release()
            for endpoint in [endpointA, endpointB] { try? store.deleteToken(for: endpoint) }
            for (key, value) in priorDefaults {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        await model.connect(
            endpoint: endpointA,
            credentials: .password(
                PasswordSession(
                    provider: "basic", username: "spencer",
                    accessToken: "synthetic-a", refreshToken: "synthetic-rt", expiresAt: 0)))
        #expect(await hold.reached.wait(), "A's pump never looked up sign-in providers")

        // The user moves on to B while A's lookup is still out.
        await model.connect(endpoint: endpointB, credentials: .sessionToken("synthetic-b"))
        let readyOnB = await eventually { model.phase == .ready(isReconnect: false) }
        #expect(readyOnB, "B never reached ready (phase: \(model.phase))")

        // A's lookup answers after all; nothing of A's may land on B.
        hold.release()
        try? await Task.sleep(for: .milliseconds(300))

        #expect(model.connection != nil, "A's pump tore down the connection to B")
        #expect(model.endpoint == endpointB)
        #expect(model.phase == .ready(isReconnect: false))
        #expect(model.pendingPasswordLogin == nil, "A's sign-in form appeared over B")
        #expect(model.connectError == nil)
    }
}
