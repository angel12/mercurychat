import Foundation
import MercuryKit
import Security
import Testing

/// Adopting the shared MercuryKit (#27, Phase 2.5 M1). Its Keychain store
/// throws where the embedded kit returned `false`, and takes the service
/// name from the app. These pin the two things the swap must not change:
/// the service existing sign-ins live under, and the "couldn't save" notice
/// on a failed write. The fakes replace only the SecItem writes, so nothing
/// here touches a real Keychain item.
@Suite("AppModel Keychain adoption", .timeLimit(.minutes(1)))
@MainActor
struct AppModelKeychainAdoptionTests {
    /// Every saved sign-in predates the rename to Mercury Chat and lives
    /// under this service. A new string would strand all of them.
    @Test func keychainServiceIsUnchanged() {
        #expect(AppModel.keychainService == "com.mercury.tokens")
    }

    /// The first `failures` writes fail with `errSecIO`; later ones
    /// succeed.
    private final class WriteBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var remainingFailures: Int
        init(failures: Int) { remainingFailures = failures }
        func add() -> OSStatus {
            lock.withLock {
                guard remainingFailures > 0 else { return errSecSuccess }
                remainingFailures -= 1
                return errSecIO
            }
        }
    }

    private func store(failingWrites failures: Int) -> KeychainTokenStore {
        let budget = WriteBudget(failures: failures)
        return KeychainTokenStore(
            service: "com.mercury.tokens.tests.fake",
            calls: KeychainCalls(
                // No existing item, so every save takes the add path.
                update: { _, _ in errSecItemNotFound },
                add: { _ in budget.add() },
                delete: { _ in errSecSuccess }))
    }

    /// `persistValidatedServer` writes UserDefaults: restore what was there.
    private func preservingDefaults<T>(_ body: () async throws -> T) async rethrows -> T {
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
        return try await body()
    }

    private func tokenServer() async throws -> HermesTestServer {
        try await HermesTestServer.start { request in
            switch request.path {
            case "/api/status": return TestHTTPResponse(200, #"{"auth_required": false}"#)
            default: return TestHTTPResponse(200, "{}")
            }
        }
    }

    /// The ready-time save of a new server's credentials. A session-token
    /// connect never rotates, so this is the only write.
    @Test(arguments: [(1, true), (0, false)])
    func aFailedSaveAtReadyShowsTheNotice(failures: Int, expectNotice: Bool) async throws {
        let server = try await tokenServer()
        defer { server.stop() }
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint

        try await preservingDefaults {
            let model = AppModel(tokenStore: store(failingWrites: failures))
            defer { model.disconnect() }
            await model.connect(endpoint: endpoint, credentials: .sessionToken("tok"))

            let ready = await eventually { model.phase == .ready(isReconnect: false) }
            #expect(ready, "connection never reached ready: \(model.phase)")
            #expect((model.keychainNotice != nil) == expectNotice)
        }
    }

    /// A token rotation during the connect probe. Only the first write (the
    /// rotation) fails; the later ready-time save succeeds, so the notice can
    /// only come from the rotation path.
    @Test func aFailedSaveOfRotatedTokensShowsTheNotice() async throws {
        let server = try await HermesTestServer.start { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": true}"#)
            case ("GET", "/api/profiles/active"):
                return request.headers["authorization"] == "Bearer fresh-at"
                    ? TestHTTPResponse(200, "{}") : TestHTTPResponse(401)
            case ("POST", "/auth/native/refresh"):
                return TestHTTPResponse(
                    200, #"{"access_token": "fresh-at", "refresh_token": "fresh-rt", "expires_at": 99}"#)
            case ("POST", "/api/auth/ws-ticket"):
                return TestHTTPResponse(200, #"{"ticket": "tik-1"}"#)
            default:
                return TestHTTPResponse(404)
            }
        }
        defer { server.stop() }
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint

        try await preservingDefaults {
            let model = AppModel(tokenStore: store(failingWrites: 1))
            defer { model.disconnect() }
            await model.connect(
                endpoint: endpoint,
                credentials: .password(
                    PasswordSession(
                        provider: "nous", username: "spencer",
                        accessToken: "stale-at", refreshToken: "stale-rt", expiresAt: 0)))

            let ready = await eventually { model.phase == .ready(isReconnect: false) }
            #expect(ready, "connection never reached ready: \(model.phase)")
            // The rotation path sets the notice from a hop to the main actor.
            #expect(await eventually { model.keychainNotice != nil })
        }
    }
}
