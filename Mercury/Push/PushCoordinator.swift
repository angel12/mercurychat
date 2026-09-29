import Foundation
import MercuryKit
import Observation

/// Where a tapped notification should go. `serverKey` nil means "the connected server"
/// (an older plugin without `device_id`, or no local pairing matched).
struct PushTapRoute: Equatable, Sendable {
    var serverKey: String?
    var profile: String
    var sessionID: String?
}

enum ProfilePushStatus: Equatable {
    case off, pairing, paired
    case error(String)
}

/// Mercury Push for the app: MercuryKit's `PushPairing` plus the user's
/// per-server choices. Platform-neutral; the iOS glue feeds it APNs events.
@MainActor
@Observable
final class PushCoordinator {
    static let keychainService = "com.mercury.push"

    static var currentEnvironment: PushEnvironment {
        #if DEBUG
            .sandbox
        #else
            .production
        #endif
    }

    private let pairing: PushPairing
    private let system: any PushSystem
    private let settingsStore: PushSettingsStore
    private let tokenTimeout: Duration

    private(set) var settings: [String: ServerPushSettings]
    private(set) var authorization: PushAuthorization = .notDetermined
    private(set) var hasToken = false
    private(set) var enableError: String?
    private(set) var tokenError: String?
    /// The connected server's profiles.
    private(set) var profileStatus: [String: ProfilePushStatus] = [:]
    /// Profiles whose pairing was confirmed with the server on this connection.
    private var confirmedThisConnection: Set<String> = []
    /// Called when a relay re-registration dropped every pairing, so the app re-syncs.
    var onReregistered: (@MainActor () -> Void)?

    init(pairing: PushPairing, system: any PushSystem, settingsStore: PushSettingsStore,
         tokenTimeout: Duration = .seconds(15)) {
        self.pairing = pairing
        self.system = system
        self.settingsStore = settingsStore
        self.tokenTimeout = tokenTimeout
        self.settings = settingsStore.load()
    }

    static func live(system: any PushSystem) -> PushCoordinator {
        PushCoordinator(
            pairing: PushPairing(
                store: PushPairingStore(service: keychainService),
                bundleID: Bundle.main.bundleIdentifier ?? "com.spencermcguire.mercurychat",
                environment: currentEnvironment),
            system: system, settingsStore: PushSettingsStore(defaults: .standard))
    }

    func settings(for serverKey: String) -> ServerPushSettings {
        settings[serverKey] ?? ServerPushSettings()
    }

    private func update(_ serverKey: String, _ body: (inout ServerPushSettings) -> Void) {
        var value = settings(for: serverKey)
        body(&value)
        settings[serverKey] = value
        settingsStore.save(settings)
    }

    // MARK: APNs events

    /// On launch: re-register only when already authorized (never prompts).
    func applicationDidLaunch() async {
        authorization = await system.authorizationStatus()
        if authorization == .authorized { system.registerForRemoteNotifications() }
    }

    func didRegister(deviceToken: Data) async {
        let before = await pairing.pairings().count
        do {
            try await pairing.updateDeviceToken(PushPairing.hexToken(deviceToken))
        } catch {
            tokenError = Self.message(for: error)
            return
        }
        tokenError = nil
        hasToken = true
        if before > 0, await pairing.pairings().isEmpty { onReregistered?() }
    }

    func didFailToRegister(_ error: Error) {
        tokenError = "Couldn't register with Apple: \(error.localizedDescription)"
    }

    func openSystemSettings() {
        system.openSystemSettings()
    }

    // MARK: User actions (connected server)

    func enable(server: HermesRESTClient, profiles: [String]) async {
        enableError = nil
        let granted: Bool
        switch await system.authorizationStatus() {
        case .authorized: granted = true
        case .denied: granted = false
        case .notDetermined: granted = await system.requestAuthorization()
        }
        authorization = granted ? .authorized : .denied
        guard granted else {
            enableError = "Notifications are turned off for Mercury Chat in Settings."
            return
        }
        if !hasToken {
            system.registerForRemoteNotifications()
            let deadline = ContinuousClock.now.advanced(by: tokenTimeout)
            while !hasToken, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard hasToken else {
                enableError = "Couldn't register with Apple. Try again."
                return
            }
        }
        update(server.endpoint.key) { $0.enabled = true }
        await sync(server: server, profiles: profiles)
    }

    func disable(server: HermesRESTClient, profiles: [String]) async {
        let key = server.endpoint.key
        update(key) { $0.enabled = false }
        for record in await pairing.pairings() where record.server == key {
            _ = try? await pairing.unpair(server: server, profile: record.profile)
        }
        for profile in profiles { profileStatus[profile] = .off }
        confirmedThisConnection = []
    }

    func setProfile(_ profile: String, enabled: Bool, server: HermesRESTClient, profiles: [String]) async {
        update(server.endpoint.key) {
            if enabled { $0.disabledProfiles.remove(profile) } else { $0.disabledProfiles.insert(profile) }
        }
        await sync(server: server, profiles: profiles)
    }

    func setPreferences(_ preferences: PushPreferences, server: HermesRESTClient) async {
        let key = server.endpoint.key
        update(key) { $0.preferences = preferences }
        for record in await pairing.pairings() where record.server == key {
            do {
                _ = try await server.updatePushPreferences(
                    profile: record.profile, deviceID: record.deviceID, preferences)
            } catch {
                profileStatus[record.profile] = .error(Self.message(for: error))
            }
        }
    }

    /// Sends a test notification through the first paired profile. Returns an error message, or nil.
    func sendTest(server: HermesRESTClient) async -> String? {
        guard let record = await pairing.pairings().first(where: { $0.server == server.endpoint.key }) else {
            return "No profile on this server is paired yet."
        }
        do {
            _ = try await server.sendTestPush(profile: record.profile, deviceID: record.deviceID)
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    /// Bring the connected server's pairings in line with the user's choices.
    func sync(server: HermesRESTClient, profiles: [String]) async {
        let key = server.endpoint.key
        let choice = settings(for: key)
        let records = await pairing.pairings().filter { $0.server == key }
        for profile in profiles {
            let wanted = choice.enabled && !choice.disabledProfiles.contains(profile)
            let isPaired = records.contains { $0.profile == profile }
            do {
                switch (wanted, isPaired) {
                case (true, false):
                    try await pairProfile(profile, server: server, preferences: choice.preferences)
                case (false, true):
                    _ = try await pairing.unpair(server: server, profile: profile)
                    profileStatus[profile] = .off
                case (true, true):
                    if confirmedThisConnection.contains(profile) {
                        profileStatus[profile] = .paired
                        continue
                    }
                    switch try await pairing.syncPairing(server: server, profile: profile) {
                    case .paired:
                        profileStatus[profile] = .paired
                        confirmedThisConnection.insert(profile)
                    case .notPaired:
                        try await pairProfile(profile, server: server, preferences: choice.preferences)
                    }
                case (false, false):
                    profileStatus[profile] = .off
                }
            } catch {
                profileStatus[profile] = .error(Self.message(for: error))
            }
        }
        for stale in records where !profiles.contains(stale.profile) {
            _ = try? await pairing.unpair(server: server, profile: stale.profile)
        }
    }

    private func pairProfile(_ profile: String, server: HermesRESTClient, preferences: PushPreferences) async throws {
        profileStatus[profile] = .pairing
        _ = try await pairing.pair(
            server: server, profile: profile, deviceName: system.deviceName, preferences: preferences)
        profileStatus[profile] = .paired
        confirmedThisConnection.insert(profile)
    }

    /// A new connection (or server): statuses and per-connection confirmations start over.
    func resetConnection() {
        profileStatus = [:]
        confirmedThisConnection = []
        enableError = nil
    }

    // MARK: Taps

    func route(for payload: PushPayload) async -> PushTapRoute {
        var serverKey: String?
        if let deviceID = payload.deviceID {
            serverKey = await pairing.pairing(forDeviceID: deviceID)?.server
        }
        var sessionID: String?
        if case .session(let id, _) = payload.route { sessionID = id }
        return PushTapRoute(serverKey: serverKey, profile: payload.profile, sessionID: sessionID)
    }

    // MARK: Copy

    static func message(for error: Error) -> String {
        switch error as? PushPairingError {
        case .devices(.pluginNotEnabled(let profile))?:
            return "Enable Mercury Push for profile \(profile) on the server: hermes -p \(profile) plugins enable mercury_push"
        case .devices(.pluginUnavailable)?:
            return "Mercury Push isn't installed on this server"
        case .devices(.relayURLInvalid)?:
            return "The server's Mercury Push relay setting is invalid"
        case .devices(.unauthorized)?:
            return "Sign in to the server again"
        case .storageUnavailable?:
            return "Unlock your device and try again"
        case .relay(.rateLimited)?:
            return "Too many requests. Try again later"
        default:
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
