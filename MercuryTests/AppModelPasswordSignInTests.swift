import Foundation
import MercuryKit
import Testing

/// Issue #99: `signIn` suspends on the password-login POST, and the connect
/// screen's Back (`cancelPasswordLogin`) stays live while it does. Back only
/// cleared the form, so the login's late answer still landed: a success
/// connected to the abandoned server and saved its session to the Keychain
/// (tearing down whatever the user had connected to meanwhile), and a
/// failure painted its error over the connect screen.
@Suite("AppModel password sign-in", .timeLimit(.minutes(1)))
@MainActor
struct AppModelPasswordSignInTests {
    /// Holds the first password-login POST until the test releases it; later
    /// logins answer at once.
    final class LoginHold: @unchecked Sendable {
        let reached = TestLatch()
        private let released = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var logins = 0
        func release() { released.signal() }
        /// True for the first login (after the hold), false for later ones.
        func arrive() -> Bool {
            lock.lock()
            logins += 1
            let first = logins == 1
            lock.unlock()
            guard first else { return false }
            reached.signal()
            _ = released.wait(timeout: .now() + 10)
            return true
        }
    }

    nonisolated static func loginSuccess(_ accessToken: String) -> TestHTTPResponse {
        TestHTTPResponse(
            200, "{}", headers: ["Set-Cookie": "hermes_session_at=\(accessToken); Path=/"])
    }

    /// A gated password server whose first login answers late, with a
    /// session (`lateSucceeds`) or a 401.
    static func gatedServer(hold: LoginHold, lateSucceeds: Bool) async throws -> HermesTestServer {
        try await HermesTestServer.start { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": true}"#)
            case ("GET", "/api/auth/providers"):
                return TestHTTPResponse(
                    200,
                    #"{"providers": [{"name": "basic", "display_name": "Password", "supports_password": true}]}"#)
            case ("POST", "/auth/password-login"):
                if hold.arrive() {
                    return lateSucceeds ? loginSuccess("abandoned-at") : TestHTTPResponse(401)
                }
                return loginSuccess("replacement-at")
            case ("POST", "/api/auth/ws-ticket"):
                return TestHTTPResponse(200, #"{"ticket": "tik-1"}"#)
            default:
                return TestHTTPResponse(200, "{}")
            }
        }
    }

    /// Snapshot the UserDefaults keys a ready-time save writes.
    static func snapshotDefaults() -> [(String, Any?)] {
        ["lastServer", "savedServers"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
    }

    static func restore(_ prior: [(String, Any?)]) {
        for (key, value) in prior {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// Connect to the gated server and wait for its password form.
    static func presentSignIn(_ model: AppModel, endpoint: ServerEndpoint) async -> Bool {
        await model.connect(endpoint: endpoint, credentials: nil)
        return await eventually { model.pendingPasswordLogin != nil }
    }

    /// Back while the login is out, then the login answers.
    @Test(arguments: [true, false])
    func backAbandonsAPendingSignIn(lateSucceeds: Bool) async throws {
        let hold = LoginHold()
        let server = try await Self.gatedServer(hold: hold, lateSucceeds: lateSucceeds)
        defer { server.stop() }

        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let prior = Self.snapshotDefaults()
        defer {
            hold.release()
            try? store.deleteToken(for: endpoint)
            Self.restore(prior)
        }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        #expect(await Self.presentSignIn(model, endpoint: endpoint), "no sign-in form")

        let signing = Task { await model.signIn(username: "spencer", password: "pw") }
        #expect(await hold.reached.wait(), "the login never reached the server")
        model.cancelPasswordLogin()
        hold.release()
        await signing.value
        // A late connect would reach ready (and save) on the pump's time.
        try? await Task.sleep(for: .milliseconds(300))

        #expect(model.connection == nil, "the abandoned sign-in connected anyway")
        #expect(model.phase == .stopped)
        #expect(model.connectError == nil, "the abandoned sign-in painted an error")
        #expect(model.pendingPasswordLogin == nil)
        #expect(store.credentials(for: endpoint) == nil, "the abandoned session was saved")
        #expect(!model.savedServers.contains { $0.urlString == endpoint.key })
    }

    /// While the login is out the user picks another server; its late answer
    /// must not tear that connection down.
    @Test(arguments: [true, false])
    func aNewerConnectSurvivesTheLateSignIn(lateSucceeds: Bool) async throws {
        let hold = LoginHold()
        let serverA = try await Self.gatedServer(hold: hold, lateSucceeds: lateSucceeds)
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
        let prior = Self.snapshotDefaults()
        defer {
            hold.release()
            for endpoint in [endpointA, endpointB] { try? store.deleteToken(for: endpoint) }
            Self.restore(prior)
        }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        #expect(await Self.presentSignIn(model, endpoint: endpointA), "no sign-in form")

        let signing = Task { await model.signIn(username: "spencer", password: "pw") }
        #expect(await hold.reached.wait(), "the login never reached the server")

        // A Recent-servers tap while A's login is still out.
        await model.connect(endpoint: endpointB, credentials: .sessionToken("synthetic-b"))
        let readyOnB = await eventually { model.phase == .ready(isReconnect: false) }
        #expect(readyOnB, "B never reached ready (phase: \(model.phase))")

        hold.release()
        await signing.value
        try? await Task.sleep(for: .milliseconds(300))

        #expect(model.connection != nil, "A's late sign-in tore down the connection to B")
        #expect(model.endpoint == endpointB)
        #expect(model.phase == .ready(isReconnect: false))
        #expect(model.connectError == nil, "A's late sign-in painted an error over B")
        #expect(store.credentials(for: endpointA) == nil, "A's abandoned session was saved")
    }

    /// Back, then a fresh sign-in to the same server that completes first:
    /// the first login's late answer must not replace or fail it.
    @Test(arguments: [true, false])
    func aReplacementSignInWinsOverTheLateOne(lateSucceeds: Bool) async throws {
        let hold = LoginHold()
        let server = try await Self.gatedServer(hold: hold, lateSucceeds: lateSucceeds)
        defer { server.stop() }

        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let prior = Self.snapshotDefaults()
        defer {
            hold.release()
            try? store.deleteToken(for: endpoint)
            Self.restore(prior)
        }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        #expect(await Self.presentSignIn(model, endpoint: endpoint), "no sign-in form")

        let first = Task { await model.signIn(username: "spencer", password: "old") }
        #expect(await hold.reached.wait(), "the login never reached the server")
        model.cancelPasswordLogin()

        #expect(await Self.presentSignIn(model, endpoint: endpoint), "no second sign-in form")
        await model.signIn(username: "spencer", password: "new")
        let saved = await eventually {
            model.savedServers.contains { $0.urlString == endpoint.key }
        }
        #expect(saved, "the replacement sign-in never reached ready (phase: \(model.phase))")

        hold.release()
        await first.value
        try? await Task.sleep(for: .milliseconds(300))

        #expect(model.connection != nil, "the late sign-in tore down the replacement")
        #expect(model.phase == .ready(isReconnect: false))
        #expect(model.connectError == nil, "the late sign-in painted an error")
        guard case .password(let session)? = store.credentials(for: endpoint) else {
            Issue.record("no password credentials were persisted")
            return
        }
        #expect(session.accessToken == "replacement-at")
    }
}
