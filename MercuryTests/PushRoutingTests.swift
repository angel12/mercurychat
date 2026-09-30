import Foundation
import MercuryKit
import Testing

@Suite("Push routing", .timeLimit(.minutes(1)))
@MainActor
struct PushRoutingTests {
    static let tokens = KeychainTokenStore(service: "com.mercury.tokens.tests")

    /// Counts `/api/status` probes: one per connect attempt.
    final class ProbeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func bump() { lock.withLock { count += 1 } }
    }

    static func hermes(
        profiles: [String] = ["default", "coder"], probes: ProbeCounter? = nil
    ) async throws -> HermesTestServer {
        let list = profiles.enumerated().map { #"{"name": "\#($1)", "is_default": \#($0 == 0)}"# }.joined(separator: ",")
        return try await HermesTestServer.start { request in
            switch request.path {
            case "/api/status":
                probes?.bump()
                return TestHTTPResponse(200, #"{"auth_required": false}"#)
            case "/api/profiles": return TestHTTPResponse(200, #"{"profiles": [\#(list)]}"#)
            default: return TestHTTPResponse(200)
            }
        }
    }

    static func model() -> AppModel {
        let keychain = InMemoryPushKeychain()
        let push = PushCoordinator(
            pairing: PushPairing(
                store: PushPairingStore(service: "com.mercury.push.tests", calls: keychain.calls, read: keychain.read),
                bundleID: "com.spencermcguire.mercurychat", environment: .sandbox),
            system: FakePushSystem(),
            settingsStore: PushSettingsStore(defaults: UserDefaults(suiteName: "push-\(UUID().uuidString)")!))
        return AppModel(tokenStore: tokens, push: push)
    }

    static func connect(_ model: AppModel, to server: HermesTestServer) async throws -> ServerEndpoint {
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        try tokens.setCredentials(.sessionToken("tok"), for: endpoint)
        await model.connect(endpoint: endpoint, credentials: .sessionToken("tok"))
        #expect(await eventually { !model.profiles.isEmpty })
        return endpoint
    }

    @Test func sameServerTapOpensTheSessionInItsProfile() async throws {
        let server = try await Self.hermes(); defer { server.stop() }
        let model = Self.model(); defer { model.disconnect() }
        let navigation = WindowNavigation()
        model.register(navigation)
        let endpoint = try await Self.connect(model, to: server)
        defer { try? Self.tokens.deleteToken(for: endpoint) }

        await model.openPushRoute(PushTapRoute(serverKey: endpoint.key, profile: "coder", sessionID: "s1"))

        #expect(model.selectedProfile == "coder")
        guard case .session(let session)? = navigation.route else { Issue.record("no session route"); return }
        #expect(session.storedID == "s1")
        #expect(session.profile == "coder")
    }

    @Test func noSessionRouteOnlySelectsTheProfile() async throws {
        let server = try await Self.hermes(); defer { server.stop() }
        let model = Self.model(); defer { model.disconnect() }
        let navigation = WindowNavigation()
        model.register(navigation)
        let endpoint = try await Self.connect(model, to: server)
        defer { try? Self.tokens.deleteToken(for: endpoint) }
        await model.openPushRoute(PushTapRoute(serverKey: nil, profile: "coder", sessionID: nil))
        #expect(model.selectedProfile == "coder")
        #expect(navigation.route == nil)
    }

    @Test func coldLaunchTapWaitsForTheConnection() async throws {
        let server = try await Self.hermes(); defer { server.stop() }
        let model = Self.model(); defer { model.disconnect() }
        let navigation = WindowNavigation()
        model.register(navigation)
        await model.openPushRoute(PushTapRoute(serverKey: nil, profile: "coder", sessionID: "s9"))
        #expect(navigation.route == nil)
        let endpoint = try await Self.connect(model, to: server)
        defer { try? Self.tokens.deleteToken(for: endpoint) }
        #expect(await eventually {
            if case .session(let s)? = navigation.route { return s.storedID == "s9" }
            return false
        })
    }

    @Test func otherServerSwitchesAutomaticallyWhenNothingIsAtRisk() async throws {
        let first = try await Self.hermes(profiles: ["a"]); defer { first.stop() }
        let second = try await Self.hermes(profiles: ["b"]); defer { second.stop() }
        let model = Self.model(); defer { model.disconnect() }
        let navigation = WindowNavigation()
        model.register(navigation)
        let secondEndpoint = try ServerEndpoint.parse("http://127.0.0.1:\(second.port)").endpoint
        try Self.tokens.setCredentials(.sessionToken("tok"), for: secondEndpoint)
        defer { try? Self.tokens.deleteToken(for: secondEndpoint) }
        let firstEndpoint = try await Self.connect(model, to: first)
        defer { try? Self.tokens.deleteToken(for: firstEndpoint) }

        await model.openPushRoute(PushTapRoute(serverKey: secondEndpoint.key, profile: "b", sessionID: "s2"))

        #expect(model.pendingPushSwitch == nil)
        #expect(await eventually { model.endpoint?.key == secondEndpoint.key && !model.profiles.isEmpty })
        #expect(await eventually {
            if case .session(let s)? = navigation.route { return s.storedID == "s2" }
            return false
        })
    }

    @Test func otherServerAsksFirstWhenADraftWouldBeLost() async throws {
        let first = try await Self.hermes(profiles: ["a"]); defer { first.stop() }
        let model = Self.model(); defer { model.disconnect() }
        let firstEndpoint = try await Self.connect(model, to: first)
        defer { try? Self.tokens.deleteToken(for: firstEndpoint) }
        let chat = try #require(model.openChat(profile: "a"))
        chat.hasUnsentDraft = true
        #expect(model.hasWorkAtRisk)

        await model.openPushRoute(PushTapRoute(serverKey: "http://127.0.0.1:1", profile: "b", sessionID: "s2"))

        #expect(model.pendingPushSwitch?.route.serverKey == "http://127.0.0.1:1")
        #expect(model.endpoint?.key == firstEndpoint.key)  // still on the first server
        model.cancelPushSwitch()
        #expect(model.pendingPushSwitch == nil)
    }

    @Test func otherServerWithoutCredentialsPrefillsTheConnectScreen() async throws {
        let first = try await Self.hermes(profiles: ["a"]); defer { first.stop() }
        let model = Self.model(); defer { model.disconnect() }
        let firstEndpoint = try await Self.connect(model, to: first)
        defer { try? Self.tokens.deleteToken(for: firstEndpoint) }
        let unknown = try ServerEndpoint.parse("http://127.0.0.1:9").endpoint
        await model.openPushRoute(PushTapRoute(serverKey: unknown.key, profile: "b", sessionID: nil))
        #expect(model.connectPrefill == unknown.key)
        #expect(model.connection == nil)
    }

    @Test func foregroundBannerIsHiddenOnlyForTheVisibleSession() async throws {
        let server = try await Self.hermes(); defer { server.stop() }
        let model = Self.model(); defer { model.disconnect() }
        let navigation = WindowNavigation()
        model.register(navigation)
        let endpoint = try await Self.connect(model, to: server)
        defer { try? Self.tokens.deleteToken(for: endpoint) }
        await model.openPushRoute(PushTapRoute(serverKey: endpoint.key, profile: "default", sessionID: "s1"))

        #expect(!model.shouldPresentPush(PushTapRoute(serverKey: endpoint.key, profile: "default", sessionID: "s1"), appActive: true))
        #expect(!model.shouldPresentPush(PushTapRoute(serverKey: nil, profile: "default", sessionID: "s1"), appActive: true))
        #expect(model.shouldPresentPush(PushTapRoute(serverKey: endpoint.key, profile: "default", sessionID: "s2"), appActive: true))
        #expect(model.shouldPresentPush(PushTapRoute(serverKey: "http://other:1", profile: "default", sessionID: "s1"), appActive: true))
        #expect(model.shouldPresentPush(PushTapRoute(serverKey: endpoint.key, profile: "default", sessionID: "s1"), appActive: false))
    }

    @Test func coldLaunchTapForTheLaunchServerOpensOnceLaunchSettles() async throws {
        let probes = ProbeCounter()
        let server = try await Self.hermes(probes: probes); defer { server.stop() }
        let model = Self.model(); defer { model.disconnect() }
        let navigation = WindowNavigation()
        model.register(navigation)
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        try Self.tokens.setCredentials(.sessionToken("tok"), for: endpoint)
        defer { try? Self.tokens.deleteToken(for: endpoint) }

        // The tap is replayed before autoConnectOnLaunch runs: it waits.
        await model.openPushRoute(PushTapRoute(serverKey: endpoint.key, profile: "coder", sessionID: "s7"))
        #expect(model.connection == nil)
        #expect(probes.value == 0)

        await model.autoConnectOnLaunch(lastServer: endpoint.key)
        #expect(await eventually {
            if case .session(let s)? = navigation.route { return s.storedID == "s7" && s.profile == "coder" }
            return false
        })
        #expect(model.endpoint?.key == endpoint.key)
        #expect(probes.value == 1)  // no second connect
    }

    @Test func coldLaunchTapForAnotherServerSwitchesAfterLaunch() async throws {
        let last = try await Self.hermes(profiles: ["a"]); defer { last.stop() }
        let tapped = try await Self.hermes(profiles: ["b"]); defer { tapped.stop() }
        let model = Self.model(); defer { model.disconnect() }
        let navigation = WindowNavigation()
        model.register(navigation)
        let lastEndpoint = try ServerEndpoint.parse("http://127.0.0.1:\(last.port)").endpoint
        let tappedEndpoint = try ServerEndpoint.parse("http://127.0.0.1:\(tapped.port)").endpoint
        try Self.tokens.setCredentials(.sessionToken("tok"), for: lastEndpoint)
        try Self.tokens.setCredentials(.sessionToken("tok"), for: tappedEndpoint)
        defer {
            try? Self.tokens.deleteToken(for: lastEndpoint)
            try? Self.tokens.deleteToken(for: tappedEndpoint)
        }

        await model.openPushRoute(PushTapRoute(serverKey: tappedEndpoint.key, profile: "b", sessionID: "s3"))
        #expect(model.connection == nil)
        await model.autoConnectOnLaunch(lastServer: lastEndpoint.key)

        #expect(await eventually {
            if case .session(let s)? = navigation.route { return s.storedID == "s3" }
            return false
        })
        #expect(model.endpoint?.key == tappedEndpoint.key)
    }

    @Test func coldLaunchTapWithNoSavedServerSwitchesOnceLaunchSettles() async throws {
        let tapped = try await Self.hermes(profiles: ["b"]); defer { tapped.stop() }
        let model = Self.model(); defer { model.disconnect() }
        let navigation = WindowNavigation()
        model.register(navigation)
        let tappedEndpoint = try ServerEndpoint.parse("http://127.0.0.1:\(tapped.port)").endpoint
        try Self.tokens.setCredentials(.sessionToken("tok"), for: tappedEndpoint)
        defer { try? Self.tokens.deleteToken(for: tappedEndpoint) }

        await model.openPushRoute(PushTapRoute(serverKey: tappedEndpoint.key, profile: "b", sessionID: "s4"))
        #expect(model.connection == nil)
        await model.autoConnectOnLaunch(lastServer: nil)

        #expect(await eventually {
            if case .session(let s)? = navigation.route { return s.storedID == "s4" }
            return false
        })
        #expect(model.endpoint?.key == tappedEndpoint.key)
    }

    @Test func failedPushSwitchDoesNotHijackALaterConnection() async throws {
        let first = try await Self.hermes(profiles: ["a"]); defer { first.stop() }
        let later = try await Self.hermes(profiles: ["c"]); defer { later.stop() }
        let model = Self.model(); defer { model.disconnect() }
        let navigation = WindowNavigation()
        model.register(navigation)
        let unreachable = try ServerEndpoint.parse("http://127.0.0.1:3").endpoint
        try Self.tokens.setCredentials(.sessionToken("tok"), for: unreachable)
        defer { try? Self.tokens.deleteToken(for: unreachable) }
        let firstEndpoint = try await Self.connect(model, to: first)
        defer { try? Self.tokens.deleteToken(for: firstEndpoint) }

        // A tap for a server that can't be reached: the switch fails.
        await model.openPushRoute(PushTapRoute(serverKey: unreachable.key, profile: "b", sessionID: "s5"))
        #expect(model.connection == nil)
        #expect(model.connectError != nil)

        // The user then connects somewhere else; the stale tap must not fire.
        let laterEndpoint = try await Self.connect(model, to: later)
        defer { try? Self.tokens.deleteToken(for: laterEndpoint) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.endpoint?.key == laterEndpoint.key)
        #expect(model.connection != nil)
        #expect(navigation.route == nil)
    }
}
