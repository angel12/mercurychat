import Foundation
import MercuryKit
import Testing

@Suite("Push coordinator", .timeLimit(.minutes(1)))
@MainActor
struct PushCoordinatorTests {
    struct Harness {
        let server: HermesTestServer
        let backend: FakePushBackend
        let system: FakePushSystem
        let coordinator: PushCoordinator
        let rest: HermesRESTClient
    }

    static func harness(
        tokenTimeout: Duration = .seconds(2),
        defaults: UserDefaults = UserDefaults(suiteName: "push-\(UUID().uuidString)")!
    ) async throws -> Harness {
        let backend = FakePushBackend()
        let server = try await HermesTestServer.start { backend.handle($0) ?? TestHTTPResponse(200) }
        let keychain = InMemoryPushKeychain()
        let pairing = PushPairing(
            relay: PushRelayClient(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!),
            store: PushPairingStore(service: "com.mercury.push.tests", calls: keychain.calls, read: keychain.read),
            bundleID: "com.spencermcguire.mercurychat", environment: .sandbox)
        let system = FakePushSystem()
        let coordinator = PushCoordinator(
            pairing: pairing, system: system,
            settingsStore: PushSettingsStore(defaults: defaults),
            tokenTimeout: tokenTimeout)
        system.onRegister = { [weak coordinator] in
            Task { await coordinator?.didRegister(deviceToken: Data(repeating: 0xab, count: 32)) }
        }
        let rest = HermesRESTClient(
            endpoint: try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint, token: "tok")
        return Harness(server: server, backend: backend, system: system, coordinator: coordinator, rest: rest)
    }

    @Test func enablePairsEveryProfile() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        await h.coordinator.enable(server: h.rest, profiles: ["default", "coder"])
        #expect(h.coordinator.enableError == nil)
        #expect(h.system.requestCalls == 1)
        #expect(h.coordinator.settings(for: h.rest.endpoint.key).enabled)
        #expect(h.coordinator.profileStatus == ["default": .paired, "coder": .paired])
        #expect(h.backend.deviceIDs(profile: "default").count == 1)
        #expect(h.backend.deviceIDs(profile: "coder").count == 1)
    }

    @Test func deniedPermissionLeavesSwitchOff() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        h.system.grant = false
        await h.coordinator.enable(server: h.rest, profiles: ["default"])
        #expect(h.coordinator.authorization == .denied)
        #expect(h.coordinator.enableError == "Notifications are turned off for Mercury Chat in Settings.")
        #expect(!h.coordinator.settings(for: h.rest.endpoint.key).enabled)
        #expect(h.backend.log.isEmpty)
    }

    @Test func tokenTimeoutFailsWithoutHanging() async throws {
        let h = try await Self.harness(tokenTimeout: .milliseconds(300)); defer { h.server.stop() }
        h.system.onRegister = nil  // APNs never answers
        await h.coordinator.enable(server: h.rest, profiles: ["default"])
        #expect(h.coordinator.enableError == "Couldn't register with Apple. Try again.")
        #expect(!h.coordinator.settings(for: h.rest.endpoint.key).enabled)
        // A second attempt still works once a token arrives. Deliver it before retrying so the
        // relay registration isn't racing the deliberately short 300 ms wait (slow CI runners).
        await h.coordinator.didRegister(deviceToken: Data(repeating: 0xab, count: 32))
        #expect(h.coordinator.hasToken)
        await h.coordinator.enable(server: h.rest, profiles: ["default"])
        #expect(h.coordinator.enableError == nil)
    }

    @Test func switchingAProfileOffUnpairsIt() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        await h.coordinator.enable(server: h.rest, profiles: ["default", "coder"])
        await h.coordinator.setProfile("coder", enabled: false, server: h.rest, profiles: ["default", "coder"])
        #expect(h.coordinator.profileStatus["coder"] == .off)
        #expect(h.backend.deviceIDs(profile: "coder").isEmpty)
        #expect(h.coordinator.settings(for: h.rest.endpoint.key).disabledProfiles == ["coder"])
        await h.coordinator.setProfile("coder", enabled: true, server: h.rest, profiles: ["default", "coder"])
        #expect(h.coordinator.profileStatus["coder"] == .paired)
    }

    @Test func syncUnpairsProfilesTheServerNoLongerLists() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        await h.coordinator.enable(server: h.rest, profiles: ["default", "gone"])
        await h.coordinator.sync(server: h.rest, profiles: ["default"])
        #expect(h.backend.deviceIDs(profile: "gone").isEmpty)
    }

    @Test func syncHealsADeviceTheServerDeactivated() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        await h.coordinator.enable(server: h.rest, profiles: ["default"])
        let old = try #require(h.backend.deviceIDs(profile: "default").first)
        h.backend.deactivate(old)
        h.coordinator.resetConnection()  // next connection
        await h.coordinator.sync(server: h.rest, profiles: ["default"])
        #expect(h.coordinator.profileStatus["default"] == .paired)
        #expect(h.backend.deviceIDs(profile: "default").contains { $0 != old })
    }

    @Test func syncPairingRunsOncePerConnection() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        await h.coordinator.enable(server: h.rest, profiles: ["default"])
        await h.coordinator.sync(server: h.rest, profiles: ["default"])
        await h.coordinator.sync(server: h.rest, profiles: ["default"])
        #expect(h.backend.log.filter { $0.hasPrefix("GET /api/plugins/mercury_push/devices") }.isEmpty)
        h.coordinator.resetConnection()
        await h.coordinator.sync(server: h.rest, profiles: ["default"])
        #expect(h.backend.log.filter { $0.hasPrefix("GET /api/plugins/mercury_push/devices") }.count == 1)
    }

    @Test func disableUnpairsEverything() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        await h.coordinator.enable(server: h.rest, profiles: ["default", "coder"])
        await h.coordinator.disable(server: h.rest, profiles: ["default", "coder"])
        #expect(!h.coordinator.settings(for: h.rest.endpoint.key).enabled)
        #expect(h.backend.deviceIDs(profile: "default").isEmpty && h.backend.deviceIDs(profile: "coder").isEmpty)
        #expect(h.coordinator.profileStatus == ["default": .off, "coder": .off])
    }

    @Test func preferencesArePatchedForEveryPairedProfile() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        await h.coordinator.enable(server: h.rest, profiles: ["default", "coder"])
        await h.coordinator.setPreferences(PushPreferences(cron: false), server: h.rest)
        #expect(h.backend.log.filter { $0.hasPrefix("PATCH") }.count == 2)
        #expect(h.coordinator.settings(for: h.rest.endpoint.key).preferences == PushPreferences(cron: false))
    }

    @Test func reregistrationIsReported() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        await h.coordinator.enable(server: h.rest, profiles: ["default"])
        var reported = false
        h.coordinator.onReregistered = { reported = true }
        h.backend.dropInstallations()  // relay forgot us: the next PUT answers 401
        await h.coordinator.didRegister(deviceToken: Data(repeating: 0xab, count: 32))
        #expect(reported)
    }

    @Test(arguments: [
        (409, #"{"error":"plugin_not_enabled","profile":"coder"}"#,
         "Enable Mercury Push for profile coder on the server: hermes -p coder plugins enable mercury_push"),
        (404, #"{"detail":"Not Found"}"#, "Mercury Push isn't installed on this server"),
        (503, #"{"error":"relay_url_invalid"}"#, "The server's Mercury Push relay setting is invalid"),
    ])
    func pairingErrorsBecomeProfileMessages(status: Int, body: String, message: String) async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        h.backend.pluginOverride = (status, body)
        await h.coordinator.enable(server: h.rest, profiles: ["coder"])
        #expect(h.coordinator.profileStatus["coder"] == .error(message))
    }

    @Test func messagesForKitErrors() {
        #expect(PushCoordinator.message(for: PushPairingError.devices(.unauthorized)) == "Sign in to the server again")
        #expect(PushCoordinator.message(for: PushPairingError.storageUnavailable(errSecInteractionNotAllowed))
            == "Unlock your device and try again")
        #expect(PushCoordinator.message(for: PushPairingError.relay(.rateLimited(retryAfter: 5)))
            == "Too many requests. Try again later")
    }

    @Test func tapResolvesServerFromDeviceID() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        await h.coordinator.enable(server: h.rest, profiles: ["coder"])
        let device = try #require(h.backend.deviceIDs(profile: "coder").first)
        let info: [AnyHashable: Any] = ["mercury": [
            "v": 1, "kind": "approval", "event_id": "e", "profile": "coder",
            "session_id": "s1", "device_id": device]]
        let payload = try #require(PushPayload(userInfo: info))
        #expect(await h.coordinator.route(for: payload)
            == PushTapRoute(serverKey: h.rest.endpoint.key, profile: "coder", sessionID: "s1"))
        let old = try #require(PushPayload(userInfo: ["mercury": ["v": 1, "kind": "cron", "event_id": "e", "profile": "coder"]]))
        #expect(await h.coordinator.route(for: old) == PushTapRoute(serverKey: nil, profile: "coder", sessionID: nil))
    }

    @Test func messageMapsBareDevicesError() {
        #expect(PushCoordinator.message(for: PushDevicesError.unauthorized) == "Sign in to the server again")
    }

    @Test func disableWhileEnableWaitsForTokenWins() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        h.system.onRegister = { [weak coordinator = h.coordinator] in
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                await coordinator?.didRegister(deviceToken: Data(repeating: 0xab, count: 32))
            }
        }
        let enabling = Task { await h.coordinator.enable(server: h.rest, profiles: ["default"]) }
        while h.system.registerCalls == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        await h.coordinator.disable(server: h.rest, profiles: ["default"])
        await enabling.value
        #expect(!h.coordinator.settings(for: h.rest.endpoint.key).enabled)
        #expect(h.backend.deviceIDs(profile: "default").isEmpty)
    }

    @Test func switchingProfileOffDuringEnableSyncIsRespected() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        let profiles = ["default", "coder"]
        let enabling = Task { await h.coordinator.enable(server: h.rest, profiles: profiles) }
        while h.backend.deviceIDs(profile: "default").isEmpty { await Task.yield() }
        await h.coordinator.setProfile("coder", enabled: false, server: h.rest, profiles: profiles)
        await enabling.value
        #expect(h.backend.deviceIDs(profile: "default").count == 1)
        #expect(h.backend.deviceIDs(profile: "coder").isEmpty)
        #expect(h.coordinator.profileStatus["coder"] == .off)
    }

    @Test func tokenErrorEndsTheWaitAndIsSurfaced() async throws {
        let h = try await Self.harness(tokenTimeout: .seconds(30)); defer { h.server.stop() }
        h.system.onRegister = { [weak coordinator = h.coordinator] in
            Task { coordinator?.didFailToRegister(NSError(domain: "apns", code: 1)) }
        }
        await h.coordinator.enable(server: h.rest, profiles: ["default"])
        #expect(h.coordinator.enableError?.hasPrefix("Couldn't register with Apple:") == true)
    }

    @Test func launchDoesNotRegisterWhenNoServerHasPushOn() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        h.system.status = .authorized
        await h.coordinator.applicationDidLaunch()
        #expect(h.coordinator.authorization == .authorized)
        #expect(h.system.registerCalls == 0)
        #expect(h.backend.log.isEmpty)
    }

    @Test func launchRegistersWhenAServerHasPushOn() async throws {
        let defaults = UserDefaults(suiteName: "push-\(UUID().uuidString)")!
        PushSettingsStore(defaults: defaults).save(["http://example.test:9119": ServerPushSettings(enabled: true)])
        let h = try await Self.harness(defaults: defaults); defer { h.server.stop() }
        h.system.status = .authorized
        await h.coordinator.applicationDidLaunch()
        #expect(h.system.registerCalls == 1)
    }

    @Test func launchNeverRegistersWithoutAuthorization() async throws {
        let defaults = UserDefaults(suiteName: "push-\(UUID().uuidString)")!
        PushSettingsStore(defaults: defaults).save(["http://example.test:9119": ServerPushSettings(enabled: true)])
        let h = try await Self.harness(defaults: defaults); defer { h.server.stop() }
        h.system.status = .notDetermined
        await h.coordinator.applicationDidLaunch()
        #expect(h.system.registerCalls == 0)
        #expect(h.system.requestCalls == 0)
    }

    @Test func operationsQueuedBeforeAResetWriteNoStatus() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        h.system.onRegister = { [weak coordinator = h.coordinator] in
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                await coordinator?.didRegister(deviceToken: Data(repeating: 0xab, count: 32))
            }
        }
        let enabling = Task { await h.coordinator.enable(server: h.rest, profiles: ["default"]) }
        while h.system.registerCalls == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        let syncing = Task { await h.coordinator.sync(server: h.rest, profiles: ["default"]) }
        try await Task.sleep(for: .milliseconds(50))  // the sync is queued behind the token wait
        h.coordinator.resetConnection()  // the user moved to another server
        await enabling.value
        await syncing.value
        #expect(h.coordinator.profileStatus.isEmpty)
        #expect(h.coordinator.enableError == nil)
        // The user's choice for that server still stands.
        #expect(h.coordinator.settings(for: h.rest.endpoint.key).enabled)
    }

    @Test func syncWithNoProfilesUnpairsNothing() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        await h.coordinator.enable(server: h.rest, profiles: ["default"])
        await h.coordinator.sync(server: h.rest, profiles: [])
        #expect(h.backend.deviceIDs(profile: "default").count == 1)
    }

    @Test func refreshAuthorizationReadsWithoutPrompting() async throws {
        let h = try await Self.harness(); defer { h.server.stop() }
        h.system.status = .denied
        await h.coordinator.refreshAuthorization()
        #expect(h.coordinator.authorization == .denied)
        #expect(h.system.requestCalls == 0)
        #expect(h.system.registerCalls == 0)
    }
}
