import Foundation
import MercuryKit
import Observation
import SwiftUI

/// Root app state: saved servers, the live connection, and the sidebar's
/// browse data (profiles, projects, recent sessions).
@MainActor
@Observable
final class AppModel {
    // MARK: Connection

    private(set) var connection: HermesConnection?
    private(set) var phase: HermesConnection.Phase = .stopped
    private(set) var serverStatus: ServerStatus?
    private(set) var endpoint: ServerEndpoint?
    var connectError: String?

    /// Contract-version drift notice (non-blocking, shown in settings/banner).
    private(set) var contractNotice: String?

    var isConnected: Bool {
        if case .ready = phase { return true }
        // Stay on the browse screen through transient reconnects.
        if case .connecting = phase, connection != nil { return true }
        if case .disconnected = phase, connection != nil { return true }
        return false
    }

    // MARK: Browse data

    private(set) var profiles: [ProfileInfo] = []
    private(set) var profilesLoading = false
    var selectedProfile: String?
    private(set) var projectTree: ProjectTree?
    private(set) var recentSessions: [SessionSummary] = []
    private(set) var browseLoading = false
    var browseError: String?

    // MARK: Navigation

    /// Sidebar selection → detail. `newSession` opens the new-session flow.
    enum Route: Hashable {
        case session(SessionSummary)
        case newSession
    }
    var route: Route?

    /// The chat currently on screen; receives the event stream.
    private(set) var activeChat: ChatController?

    /// Create (and register) the controller for a route. The view owns the
    /// begin() call; registration here is what routes gateway events.
    func openChat(profile: String?) -> ChatController {
        let controller = ChatController(
            connection: connection!, profile: profile ?? selectedProfile)
        activeChat = controller
        return controller
    }

    func closeChat(_ controller: ChatController) {
        guard activeChat === controller else { return }
        activeChat = nil
        Task {
            await controller.teardown()
            await refreshProjects()
        }
    }

    private let tokenStore = KeychainTokenStore()
    private var updatePump: Task<Void, Never>?

    /// Monotonic guard for the connect flow: `connect()` suspends across the
    /// status/validation probes and the WS dial, so an overlapping connect
    /// (second saved-server tap) or a disconnect can land mid-flight. Only
    /// the newest generation may publish state.
    private var connectGeneration = 0

    // MARK: Saved servers

    struct SavedServer: Codable, Identifiable, Equatable {
        var urlString: String
        var id: String { urlString }
    }

    private(set) var savedServers: [SavedServer] =
        (try? JSONDecoder().decode(
            [SavedServer].self,
            from: UserDefaults.standard.data(forKey: "savedServers") ?? Data())) ?? []

    private func persistServers() {
        if let data = try? JSONEncoder().encode(savedServers) {
            UserDefaults.standard.set(data, forKey: "savedServers")
        }
    }

    func savedCredentials(for endpoint: ServerEndpoint) -> ServerCredentials? {
        tokenStore.credentials(for: endpoint)
    }

    func forgetServer(_ server: SavedServer) {
        savedServers.removeAll { $0.urlString == server.urlString }
        persistServers()
        if let parsed = try? ServerEndpoint.parse(server.urlString) {
            tokenStore.deleteToken(for: parsed.endpoint)
            if endpoint?.key == parsed.endpoint.key { disconnect() }
        }
    }

    // MARK: Connect flow

    /// Set when a gated server advertises a username/password provider and
    /// the user must sign in before the gateway can open.
    struct PendingPasswordLogin: Equatable {
        var endpoint: ServerEndpoint
        var providerName: String
        var providerDisplayName: String
        var prefillUsername: String = ""
    }
    private(set) var pendingPasswordLogin: PendingPasswordLogin?

    func autoConnectOnLaunch() async {
        guard connection == nil,
            let last = UserDefaults.standard.string(forKey: "lastServer"),
            let parsed = try? ServerEndpoint.parse(last),
            let credentials = tokenStore.credentials(for: parsed.endpoint)
        else { return }
        await connect(endpoint: parsed.endpoint, credentials: credentials)
    }

    /// Parse input (URL, host:port, or dashboard URL with `?token=`),
    /// validate, and open the gateway.
    func connect(input: String, token explicitToken: String?) async {
        connectError = nil
        do {
            let parsed = try ServerEndpoint.parse(input)
            let token = explicitToken?.isEmpty == false ? explicitToken : parsed.embeddedToken
            await connect(
                endpoint: parsed.endpoint,
                credentials: token.map { .sessionToken($0) })
        } catch {
            connectError = error.localizedDescription
        }
    }

    func connect(endpoint: ServerEndpoint, credentials: ServerCredentials?) async {
        disconnect()
        connectGeneration += 1
        let generation = connectGeneration
        connectError = nil
        pendingPasswordLogin = nil
        self.endpoint = endpoint

        // One authenticator shared by the probe and the connection, so a
        // token refresh done during validation carries into the gateway.
        // Rotations land back in the keychain.
        let store = tokenStore
        let authenticator = HermesAuthenticator(
            endpoint: endpoint, credentials: credentials
        ) { rotated in
            store.setCredentials(rotated, for: endpoint)
        }
        let probe = HermesRESTClient(endpoint: endpoint, authenticator: authenticator)
        do {
            let status = try await probe.status()
            guard generation == connectGeneration else { return }
            serverStatus = status

            var isPasswordMode = false
            if case .password = credentials { isPasswordMode = true }
            if status.authRequired, !isPasswordMode {
                // Gated bind — a loopback session token can't authenticate.
                await presentGatedLogin(endpoint: endpoint, generation: generation)
                return
            }
            try await probe.validateToken()
            guard generation == connectGeneration else { return }
        } catch HermesError.sessionExpired {
            guard generation == connectGeneration else { return }
            await presentGatedLogin(
                endpoint: endpoint,
                note: HermesError.sessionExpired.errorDescription,
                generation: generation)
            return
        } catch let error as HermesError {
            guard generation == connectGeneration else { return }
            connectError = error.errorDescription
            return
        } catch {
            guard generation == connectGeneration else { return }
            connectError = "Could not reach \(endpoint.displayName): \(error.localizedDescription)"
            return
        }

        // The authed HTTP probe passed, but don't persist yet: a server can
        // pass REST and still refuse the socket (Host/Origin guards, ticket
        // rules) — the documented false-positive trap. Dial first; the
        // connection is saved when the gateway reaches ready.
        let connection = HermesConnection(endpoint: endpoint, authenticator: authenticator)
        self.connection = connection
        startUpdatePump(connection, credentialsToSave: credentials)
        await connection.start()
    }

    /// Sign in to a gated server with the pending password provider, then
    /// connect with the minted tokens.
    func signIn(username: String, password: String) async {
        guard let pending = pendingPasswordLogin else { return }
        connectError = nil
        do {
            let session = try await HermesAuthenticator.logIn(
                endpoint: pending.endpoint,
                provider: pending.providerName,
                username: username,
                password: password)
            await connect(endpoint: pending.endpoint, credentials: .password(session))
        } catch let error as HermesError {
            connectError = error.errorDescription
        } catch {
            connectError = error.localizedDescription
        }
    }

    func cancelPasswordLogin() {
        pendingPasswordLogin = nil
        connectError = nil
    }

    /// Look up the gated server's sign-in options; surface the password form
    /// when available. (Native PKCE lands in Milestone 5.)
    private func presentGatedLogin(
        endpoint: ServerEndpoint, note: String? = nil, generation: Int? = nil
    ) async {
        let providers =
            (try? await HermesAuthenticator.authProviders(endpoint: endpoint)) ?? []
        if let generation, generation != connectGeneration { return }
        guard let passwordProvider = providers.first(where: \.supportsPassword) else {
            connectError =
                "This server only offers browser (OAuth) sign-in, which Mercury doesn't support yet. Configure dashboard.basic_auth on the server for username/password access, or run it on loopback."
            return
        }
        var prefill = ""
        if case .password(let saved)? = tokenStore.credentials(for: endpoint) {
            prefill = saved.username
        }
        pendingPasswordLogin = PendingPasswordLogin(
            endpoint: endpoint,
            providerName: passwordProvider.name,
            providerDisplayName: passwordProvider.displayName,
            prefillUsername: prefill)
        connectError = note
    }

    func disconnect() {
        connectGeneration += 1  // invalidate any in-flight connect()
        updatePump?.cancel()
        updatePump = nil
        let connection = connection
        self.connection = nil
        if let connection {
            Task { await connection.stop() }
        }
        phase = .stopped
        route = nil
        profiles = []
        projectTree = nil
        recentSessions = []
        selectedProfile = nil
        contractNotice = nil
    }

    /// Immediate re-dial on foreground (backoff skip).
    func appBecameActive() {
        guard let connection else { return }
        Task { await connection.pokeReconnect() }
    }

    func requestNewSession() {
        guard isConnected else { return }
        route = .newSession
    }

    private func startUpdatePump(
        _ connection: HermesConnection, credentialsToSave: ServerCredentials?
    ) {
        var pendingSave = credentialsToSave
        updatePump = Task { [weak self] in
            for await update in await connection.updates() {
                guard let self, !Task.isCancelled else { return }
                switch update {
                case .phase(let phase):
                    self.phase = phase
                    if case .ready(let isReconnect) = phase {
                        if let credentials = pendingSave, let endpoint = self.endpoint {
                            // Authed probe + live socket: now the connection
                            // has earned a spot in the saved list.
                            self.persistValidatedServer(
                                endpoint: endpoint, credentials: credentials)
                            pendingSave = nil
                        }
                        if !isReconnect {
                            await self.loadBrowseData()
                        }
                        await self.activeChat?.connectionBecameReady(
                            isReconnect: isReconnect)
                    }
                    if case .authExpired = phase {
                        // Dead refresh token: back to the connect screen with
                        // the sign-in form up. Present BEFORE disconnect —
                        // disconnect cancels this pump task.
                        if let endpoint = self.endpoint {
                            await self.presentGatedLogin(
                                endpoint: endpoint,
                                note: HermesError.sessionExpired.errorDescription)
                        }
                        self.disconnect()
                        return
                    }
                case .event(let event):
                    self.activeChat?.handle(event: event)
                    self.handleGlobalEvent(event)
                }
            }
        }
    }

    private func persistValidatedServer(
        endpoint: ServerEndpoint, credentials: ServerCredentials
    ) {
        tokenStore.setCredentials(credentials, for: endpoint)
        UserDefaults.standard.set(endpoint.key, forKey: "lastServer")
        if !savedServers.contains(where: { $0.urlString == endpoint.key }) {
            savedServers.append(SavedServer(urlString: endpoint.key))
            persistServers()
        }
    }

    /// Connection-level events (session-scoped ones are routed by the chat
    /// controller in Milestone 3).
    private func handleGlobalEvent(_ event: GatewayEvent) {
        switch event.type {
        case GatewayEvent.Kind.sessionsChanged:
            Task { await refreshProjects() }
        default:
            break
        }
    }

    // MARK: Browse data

    func loadBrowseData() async {
        guard let connection else { return }
        browseError = nil

        // Profiles are slow (walks skill trees) — load independently so they
        // never block the sessions list.
        if profiles.isEmpty {
            profilesLoading = true
            Task {
                defer { profilesLoading = false }
                if let loaded = try? await connection.rest.profiles() {
                    profiles = loaded
                    if selectedProfile == nil {
                        selectedProfile =
                            loaded.first(where: \.isDefault)?.name ?? loaded.first?.name
                    }
                }
            }
        }
        await refreshProjects()
        await checkContractVersion()
    }

    func refreshProjects() async {
        guard let connection else { return }
        browseLoading = true
        defer { browseLoading = false }
        do {
            projectTree = try await connection.projectsTree()
            let profile = selectedProfile ?? "all"
            recentSessions = try await connection.rest.profileSessions(
                profile: profile, limit: 30)
            browseError = nil
        } catch let error as HermesError {
            if case .rpcError(HermesError.RPCCode.methodNotFound, _) = error {
                // Older backend without projects.* — degrade to grouping the
                // flat list by repo root / cwd.
                await degradeToFlatSessions()
            } else {
                browseError = error.errorDescription
            }
        } catch {
            browseError = error.localizedDescription
        }
    }

    private func degradeToFlatSessions() async {
        guard let connection else { return }
        guard
            let sessions = try? await connection.rest.profileSessions(
                profile: selectedProfile ?? "all", limit: 50)
        else { return }
        var groups: [String: [SessionSummary]] = [:]
        for session in sessions {
            let key = session.gitRepoRoot ?? session.cwd ?? ProjectInfo.noProjectID
            groups[key, default: []].append(session)
        }
        let projects = groups.map { key, _ -> ProjectInfo in
            var json: [String: JSONValue] = [
                "id": .string(key),
                "name": .string(
                    key == ProjectInfo.noProjectID
                        ? "Home" : (key as NSString).lastPathComponent),
            ]
            if key != ProjectInfo.noProjectID { json["primary_path"] = .string(key) }
            return ProjectInfo(json: .object(json))!
        }
        projectTree = ProjectTree(json: .object(["projects": .array([])]))
        projectTree?.projects = projects.sorted { $0.name < $1.name }
        recentSessions = sessions
    }

    func selectProfile(_ name: String) async {
        guard selectedProfile != name else { return }
        selectedProfile = name
        // A profile is a whole isolated HERMES_HOME — drop the stale rows so
        // the sessions page shows its loading state, then refresh everything.
        recentSessions = []
        projectTree = nil
        await refreshProjects()
    }

    /// Cheap probe for `desktop_contract` drift: create + close a throwaway
    /// lazy session (no DB row until first prompt) and compare.
    private func checkContractVersion() async {
        guard let connection, contractNotice == nil else { return }
        guard let handle = try? await connection.createSession() else { return }
        if let contract = handle.desktopContract,
            contract != GatewayClient.builtAgainstDesktopContract
        {
            contractNotice =
                "This server speaks desktop contract v\(contract); Mercury was built against v\(GatewayClient.builtAgainstDesktopContract). Most things should still work, but expect rough edges."
        }
        await connection.closeSession(sessionID: handle.runtimeID)
    }
}
