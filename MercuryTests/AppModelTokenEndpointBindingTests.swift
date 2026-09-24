import ChatCore
import Foundation
import MercuryKit
import Testing

/// Issue #104: a token autofilled from A's dashboard URL (or typed for A and
/// submitted) stayed in the connect form after the user edited the server to
/// B, and the next Connect sent A's token to B. Drives the connect form state
/// the way ConnectView does against two real fake servers, with synthetic
/// tokens only, and checks what B actually receives.
@Suite("AppModel token endpoint binding", .timeLimit(.minutes(1)))
@MainActor
struct AppModelTokenEndpointBindingTests {
    /// Every session-token header a server saw, in arrival order.
    final class SeenTokens: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [String] = []
        func record(_ request: TestHTTPRequest) {
            guard let token = request.headers["x-hermes-session-token"] else { return }
            lock.withLock { tokens.append(token) }
        }
        var all: [String] { lock.withLock { tokens } }
    }

    @Test func autofilledTokenForAIsNotSentToB() async throws {
        try await assertBNeverSeesAToken { form, aPort in
            form.setServer("http://127.0.0.1:\(aPort)/?token=synthetic-a")
        }
    }

    @Test func manuallyEnteredTokenForAIsNotSentToB() async throws {
        try await assertBNeverSeesAToken { form, aPort in
            form.setServer("127.0.0.1:\(aPort)")
            form.setToken("synthetic-a")
        }
    }

    /// Server A accepts the probe but rejects the token, so the attempt
    /// fails the way a stale dashboard token does. Server B is ungated and
    /// validates whatever token arrives — the case where a leaked token
    /// would actually be transmitted.
    private func assertBNeverSeesAToken(
        fill: (inout ConnectFormState, UInt16) -> Void
    ) async throws {
        let seenByA = SeenTokens()
        let serverA = try await HermesTestServer.start { request in
            seenByA.record(request)
            switch request.path {
            case "/api/status": return TestHTTPResponse(200, #"{"auth_required": false}"#)
            default: return TestHTTPResponse(401)
            }
        }
        defer { serverA.stop() }
        let seenByB = SeenTokens()
        let serverB = try await HermesTestServer.start { request in
            seenByB.record(request)
            switch request.path {
            case "/api/status": return TestHTTPResponse(200, #"{"auth_required": false}"#)
            default: return TestHTTPResponse(200)
            }
        }
        defer { serverB.stop() }

        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let endpoints = try [serverA, serverB].map {
            try ServerEndpoint.parse("http://127.0.0.1:\($0.port)").endpoint
        }
        defer { for endpoint in endpoints { try? store.deleteToken(for: endpoint) } }
        // B reaching ready persists it: restore whatever this domain held.
        let priorDefaults = ["lastServer", "savedServers"].map {
            ($0, UserDefaults.standard.object(forKey: $0))
        }
        defer {
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
        var form = ConnectFormState()

        fill(&form, serverA.port)
        form.recordAttempt()
        await model.connect(input: form.server, token: form.connectToken)
        #expect(model.connectError != nil, "A was scripted to reject the token")
        #expect(seenByA.all.contains("synthetic-a"), "A never received its own token")

        form.setServer("http://127.0.0.1:\(serverB.port)")
        #expect(form.tokenWasCleared)
        form.recordAttempt()
        await model.connect(input: form.server, token: form.connectToken)

        #expect(!seenByB.all.contains("synthetic-a"), "B received A's token: \(seenByB.all)")
    }
}
