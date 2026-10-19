import Foundation
import MercuryKit
import Observation
import os

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
    private static let logger = Logger(subsystem: "Mercury", category: "Push")

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
    /// The connected server's paired profiles whose plugin supports session scopes
    /// (mercury-push 0.2.0+), learned from the device the server reports.
    private(set) var scopeSupportedProfiles: Set<String> = []
    /// Whether the connected server can limit notifications to this device's sessions.
    var supportsSessionScope: Bool { !scopeSupportedProfiles.isEmpty }
    /// Bumped by `resetConnection()`; work started under an older value must not write status.
    private var generation = 0
    /// The most recent queued mutating operation; the next one waits for it (FIFO).
    private var tail: Task<Void, Never>?
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

    /// Runs `operation` after every previously queued operation has finished.
    private func serialized(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        await task.value
    }

    private func update(_ serverKey: String, _ body: (inout ServerPushSettings) -> Void) {
        var value = settings(for: serverKey)
        body(&value)
        settings[serverKey] = value
        settingsStore.save(settings)
    }

    // MARK: APNs events

    /// On launch: re-register only when already authorized (never prompts) and some
    /// server has push on — otherwise the token would reach the relay for nothing.
    /// `enable` registers on demand.
    func applicationDidLaunch() async {
        authorization = await system.authorizationStatus()
        if authorization == .authorized, settings.values.contains(where: \.enabled) {
            system.registerForRemoteNotifications()
        }
    }

    /// Reads the current permission without prompting (the settings sheet calls this on appear).
    func refreshAuthorization() async {
        authorization = await system.authorizationStatus()
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

    // Each public wrapper captures `generation` when the operation is queued, so one
    // queued for a server the user has since left writes no status when it runs.

    func enable(server: HermesRESTClient, profiles: [String]) async {
        let gen = generation
        await serialized { await self.performEnable(server: server, profiles: profiles, gen: gen) }
    }

    private func performEnable(server: HermesRESTClient, profiles: [String], gen: Int) async {
        setEnableError(nil, gen)
        let granted: Bool
        switch await system.authorizationStatus() {
        case .authorized: granted = true
        case .denied: granted = false
        case .notDetermined: granted = await system.requestAuthorization()
        }
        authorization = granted ? .authorized : .denied
        guard granted else {
            setEnableError(Self.deniedMessage, gen)
            return
        }
        if !hasToken {
            tokenError = nil
            system.registerForRemoteNotifications()
            let deadline = ContinuousClock.now.advanced(by: tokenTimeout)
            while !hasToken, tokenError == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard hasToken else {
                setEnableError(tokenError ?? "Couldn't register with Apple. Try again.", gen)
                return
            }
        }
        update(server.endpoint.key) { $0.enabled = true }
        await performSync(server: server, profiles: profiles, gen: gen)
    }

    static let deniedMessage = "Notifications are turned off for Mercury Chat in Settings."

    private func setEnableError(_ message: String?, _ gen: Int) {
        if gen == generation { enableError = message }
    }

    func disable(server: HermesRESTClient, profiles: [String]) async {
        await serialized { await self.performDisable(server: server, profiles: profiles) }
    }

    private func performDisable(server: HermesRESTClient, profiles: [String]) async {
        let key = server.endpoint.key
        update(key) { $0.enabled = false }
        for record in await pairing.pairings() where record.server == key {
            _ = try? await pairing.unpair(server: server, profile: record.profile)
        }
        for profile in profiles { profileStatus[profile] = .off }
        confirmedThisConnection = []
        scopeSupportedProfiles = []
    }

    func setProfile(_ profile: String, enabled: Bool, server: HermesRESTClient, profiles: [String]) async {
        let gen = generation
        await serialized {
            self.update(server.endpoint.key) {
                if enabled { $0.disabledProfiles.remove(profile) } else { $0.disabledProfiles.insert(profile) }
            }
            await self.performSync(server: server, profiles: profiles, gen: gen)
        }
    }

    func setPreferences(_ preferences: PushPreferences, server: HermesRESTClient) async {
        await serialized { await self.performSetPreferences(preferences, server: server) }
    }

    private func performSetPreferences(_ preferences: PushPreferences, server: HermesRESTClient) async {
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

    func setSessionScope(_ scope: PushSessionScope, server: HermesRESTClient) async {
        await serialized { await self.performSetSessionScope(scope, server: server) }
    }

    private func performSetSessionScope(_ scope: PushSessionScope, server: HermesRESTClient) async {
        let key = server.endpoint.key
        update(key) { $0.sessionScope = scope }
        for record in await pairing.pairings() where record.server == key {
            do {
                _ = try await server.updatePushSessionScope(profile: record.profile, deviceID: record.deviceID, scope)
            } catch {
                profileStatus[record.profile] = .error(Self.message(for: error))
            }
        }
    }

    /// This device started `sessionID` or sent a message in it: make it the session's owner, so a
    /// device set to "only this device's sessions" is notified about it. Sent whatever this
    /// device's own scope is (using a session here takes it over from another device). Best
    /// effort: only when the plugin supports it, and a failure is logged, never shown.
    /// Not queued behind pairing work, so a send is never held up.
    func claim(server: HermesRESTClient, profile: String, sessionID: String) async {
        guard settings(for: server.endpoint.key).enabled, scopeSupportedProfiles.contains(profile) else { return }
        do {
            try await pairing.claimSession(server: server, profile: profile, sessionID: sessionID)
        } catch {
            Self.logger.info("Push session claim failed: \(Self.message(for: error), privacy: .public)")
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
        let gen = generation
        await serialized { await self.performSync(server: server, profiles: profiles, gen: gen) }
    }

    private func performSync(server: HermesRESTClient, profiles: [String], gen: Int) async {
        let key = server.endpoint.key
        let choice = settings(for: key)
        let records = await pairing.pairings().filter { $0.server == key }
        for profile in profiles {
            let wanted = choice.enabled && !choice.disabledProfiles.contains(profile)
            let isPaired = records.contains { $0.profile == profile }
            do {
                switch (wanted, isPaired) {
                case (true, false):
                    try await pairProfile(profile, server: server, choice: choice, gen: gen)
                case (false, true):
                    _ = try await pairing.unpair(server: server, profile: profile)
                    setStatus(profile, .off, gen)
                    if gen == generation { scopeSupportedProfiles.remove(profile) }
                case (true, true):
                    if confirmedThisConnection.contains(profile) {
                        setStatus(profile, .paired, gen)
                        continue
                    }
                    switch try await pairing.syncPairing(server: server, profile: profile) {
                    case .paired(let device):
                        try await reconcileScope(device, profile: profile, server: server, scope: choice.sessionScope, gen: gen)
                        setStatus(profile, .paired, gen)
                        confirm(profile, gen)
                    case .notPaired:
                        try await pairProfile(profile, server: server, choice: choice, gen: gen)
                    }
                case (false, false):
                    setStatus(profile, .off, gen)
                }
            } catch {
                setStatus(profile, .error(Self.message(for: error)), gen)
            }
        }
        // An empty list is no evidence the server dropped every profile: unpair nothing.
        guard !profiles.isEmpty else { return }
        for stale in records where !profiles.contains(stale.profile) {
            _ = try? await pairing.unpair(server: server, profile: stale.profile)
        }
    }

    private func setStatus(_ profile: String, _ status: ProfilePushStatus, _ gen: Int) {
        if gen == generation { profileStatus[profile] = status }
    }

    private func confirm(_ profile: String, _ gen: Int) {
        if gen == generation { confirmedThisConnection.insert(profile) }
    }

    private func pairProfile(
        _ profile: String, server: HermesRESTClient, choice: ServerPushSettings, gen: Int
    ) async throws {
        setStatus(profile, .pairing, gen)
        _ = try await pairing.pair(
            server: server, profile: profile, deviceName: system.deviceName, preferences: choice.preferences,
            sessionScope: choice.sessionScope)
        setStatus(profile, .paired, gen)
        confirm(profile, gen)
        // `pair` can't tell whether this plugin supports session scopes (an older one ignores the
        // scope); one read of the device can. Not worth failing a pairing that succeeded.
        if case .paired(let device)? = try? await pairing.syncPairing(server: server, profile: profile) {
            try? await reconcileScope(device, profile: profile, server: server, scope: choice.sessionScope, gen: gen)
        }
    }

    /// Records whether `device`'s plugin supports session scopes and, when it does, puts the
    /// device's scope back to the user's choice if it drifted (another client changed it).
    private func reconcileScope(
        _ device: PushDevice, profile: String, server: HermesRESTClient, scope: PushSessionScope, gen: Int
    ) async throws {
        guard let current = device.sessionScope else {
            if gen == generation { scopeSupportedProfiles.remove(profile) }
            return
        }
        if gen == generation { scopeSupportedProfiles.insert(profile) }
        if current != scope {
            _ = try await server.updatePushSessionScope(profile: profile, deviceID: device.deviceID, scope)
        }
    }

    /// A new connection (or server): statuses and per-connection confirmations start over.
    func resetConnection() {
        generation += 1
        profileStatus = [:]
        confirmedThisConnection = []
        scopeSupportedProfiles = []
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
        var error = error
        if case .devices(let inner)? = error as? PushPairingError { error = inner }
        switch error as? PushDevicesError {
        case .pluginNotEnabled(let profile)?:
            return "Enable Mercury Push for profile \(profile) on the server: hermes -p \(profile) plugins enable mercury_push"
        case .pluginUnavailable?:
            return "Mercury Push isn't installed on this server"
        case .relayURLInvalid?:
            return "The server's Mercury Push relay setting is invalid"
        case .featureUnsupported?:
            return "Update Mercury Push on the server to use this"
        case .unauthorized?:
            return "Sign in to the server again"
        default:
            break
        }
        switch error as? PushPairingError {
        case .storageUnavailable?:
            return "Unlock your device and try again"
        case .relay(.rateLimited)?:
            return "Too many requests. Try again later"
        default:
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
