import Foundation
import MercuryKit
import Network
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

    /// A keychain credential write failed (locked keychain, auth failure):
    /// the stale item persists and the next launch will present dead
    /// credentials. Non-blocking — the live connection is unaffected.
    private(set) var keychainNotice: String?

    private static let keychainWriteFailureNotice =
        "Couldn't save credentials to the Keychain — you may need to sign in again next launch."

    /// Whether the gateway speaks the `profiles.*` RPC family Bot Mode is
    /// built on. `nil` until probed (or when the probe failed on transport) —
    /// the future Bots tab gates on `== true`.
    private(set) var botModeSupported: Bool?

    var isConnected: Bool {
        if case .ready = phase { return true }
        // Stay on the browse screen through transient reconnects — and
        // through a give-up, where the banner offers the retry.
        if case .connecting = phase, connection != nil { return true }
        if case .disconnected = phase, connection != nil { return true }
        if case .unreachable = phase, connection != nil { return true }
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

    // MARK: Bot Mode roster

    /// Which list the sidebar shows. Bots is offered only while
    /// `botModeSupported == true`.
    enum SidebarTab: String { case sessions, bots }
    var sidebarTab: SidebarTab = .sessions

    private(set) var bots: [BotSummary] = []
    private(set) var botsLoading = false
    var botsError: String?
    /// Fetched avatar images by profile name. Session-lived: cleared on
    /// disconnect, refetched on demand.
    private(set) var botAvatars: [String: Data] = [:]
    private var botAvatarFetchesInFlight: Set<String> = []
    /// Roster refreshes are throttled: `profiles.list` with sessions walks
    /// every profile's state.db, so sessions.changed bursts (one per turn
    /// end) must not stack listing calls.
    private var lastBotsRefresh: Date?

    // MARK: Navigation

    /// A bot roster row's click target: the profile plus its server-resolved
    /// canonical Bot Chat (nil stored id = no canonical chat yet — create it).
    struct BotChatTarget: Hashable {
        var profile: String
        var displayTitle: String
        /// The canonical chat's live tip (`resolved_id`), resolved by the
        /// server at listing time.
        var storedID: String?
    }

    /// Sidebar selection → detail. `newSession` opens the new-session flow.
    enum Route: Hashable {
        case session(SessionSummary)
        case newSession(cwd: String?)
        case botChat(BotChatTarget)
    }
    var route: Route?

    /// The chat currently on screen; receives the event stream.
    private(set) var activeChat: ChatController?

    /// Create (and register) the controller for a route. The view owns the
    /// begin() call; registration here is what routes gateway events.
    /// nil when the connection is already gone — the caller is a `.task`
    /// body, which runs on a later MainActor hop (even when already
    /// cancelled), so a disconnect can land first (#48).
    func openChat(profile: String?) -> ChatController? {
        guard let connection else { return nil }
        let controller = ChatController(
            connection: connection, profile: profile ?? selectedProfile)
        activeChat = controller
        return controller
    }

    func closeChat(_ controller: ChatController) {
        guard activeChat === controller else { return }
        controller.invalidate()
        activeChat = nil
        Task {
            await controller.teardown()
            await refreshProjects()
        }
    }

    private let tokenStore: KeychainTokenStore
    private var updatePump: Task<Void, Never>?

    /// Tests inject an isolated keychain service so fixtures never touch
    /// the real `com.mercury.tokens` items.
    init(tokenStore: KeychainTokenStore = KeychainTokenStore()) {
        self.tokenStore = tokenStore
    }

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
            insecureAllowedServers.removeAll { $0 == parsed.endpoint.key }
            if endpoint?.key == parsed.endpoint.key { disconnect() }
        }
    }

    // MARK: Connect flow

    // MARK: Insecure-transport gate

    /// Set when a connect attempt targeted plaintext HTTP on a non-loopback
    /// host: everything (passwords, tokens, prompts, sudo secrets) would
    /// cross the network unencrypted. The connect screen shows a strong
    /// warning with an explicit "connect anyway" override.
    struct PendingInsecureConnect: Equatable {
        var endpoint: ServerEndpoint
        var credentials: ServerCredentials?
    }
    private(set) var pendingInsecureConnect: PendingInsecureConnect?

    /// Endpoint keys the user has explicitly opted into plaintext HTTP for.
    private var insecureAllowedServers: [String] {
        get { UserDefaults.standard.stringArray(forKey: "insecureAllowedServers") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "insecureAllowedServers") }
    }

    /// User accepted the plaintext-HTTP warning: remember the opt-in for
    /// this endpoint (so auto-connect keeps working) and retry the connect.
    func connectInsecureAnyway() async {
        guard let pending = pendingInsecureConnect else { return }
        pendingInsecureConnect = nil
        if !insecureAllowedServers.contains(pending.endpoint.key) {
            insecureAllowedServers.append(pending.endpoint.key)
        }
        await connect(endpoint: pending.endpoint, credentials: pending.credentials)
    }

    func dismissInsecureConnect() {
        pendingInsecureConnect = nil
    }

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
        pendingInsecureConnect = nil
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
        pendingInsecureConnect = nil

        if endpoint.isPlaintextNonLoopback,
            !insecureAllowedServers.contains(endpoint.key)
        {
            pendingInsecureConnect = PendingInsecureConnect(
                endpoint: endpoint, credentials: credentials)
            return
        }
        self.endpoint = endpoint

        // One authenticator shared by the probe and the connection, so a
        // token refresh done during validation carries into the gateway.
        // Rotations land back in the keychain.
        let store = tokenStore
        let authenticator = HermesAuthenticator(
            endpoint: endpoint, credentials: credentials
        ) { [weak self] rotated in
            if !store.setCredentials(rotated, for: endpoint) {
                Task { @MainActor [weak self] in
                    self?.keychainNotice = Self.keychainWriteFailureNotice
                }
            }
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
        startPathMonitor()
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
        pendingOAuthLogin = nil
        cancelOAuthFlow()
        connectError = nil
    }

    /// Tear down the in-flight PKCE flow: cancel the task AND the loopback
    /// listener. The listener otherwise keeps its port open (and accepts a
    /// stale callback) until its independent five-minute timeout — task
    /// cancellation alone doesn't reach the window between `start()` and
    /// `waitForRedirect()`.
    private func cancelOAuthFlow() {
        guard let flow = oauthFlow else { return }
        flow.task.cancel()
        Task { await flow.listener.cancel() }
        oauthFlow = nil
        oauthBrowserURL = nil
    }

    // MARK: Native PKCE (RFC 8252)

    private var oauthFlow: (listener: LoopbackRedirectListener, task: Task<Void, Never>)?

    /// URL the connect screen must open in the system browser, published
    /// when `signInWithBrowser` starts.
    private(set) var oauthBrowserURL: URL?

    /// Run the native-PKCE flow: loopback listener → browser → code
    /// exchange → connect with bearer tokens.
    func signInWithBrowser() async {
        guard let pending = pendingOAuthLogin else { return }
        connectError = nil
        cancelOAuthFlow()

        let listener = LoopbackRedirectListener()
        let challenge = PKCEChallenge.generate()
        do {
            let redirectURI = try await listener.start()
            oauthBrowserURL = HermesAuthenticator.nativeAuthorizeURL(
                endpoint: pending.endpoint,
                provider: pending.providerName,
                challenge: challenge,
                redirectURI: redirectURI)
        } catch {
            connectError = error.localizedDescription
            return
        }

        let task = Task { [weak self] in
            do {
                let redirect = try await listener.waitForRedirect()
                guard redirect.state == challenge.state else {
                    throw HermesError.malformedResponse(
                        "sign-in state mismatch — try again")
                }
                let session = try await HermesAuthenticator.exchangeNativeCode(
                    endpoint: pending.endpoint,
                    code: redirect.code,
                    verifier: challenge.verifier)
                guard let self, !Task.isCancelled else { return }
                self.oauthBrowserURL = nil
                self.pendingOAuthLogin = nil
                // Release the finished flow before connect(): connect's
                // disconnect() tears down any still-pending flow, and this
                // task must not cancel itself.
                self.oauthFlow = nil
                await self.connect(
                    endpoint: pending.endpoint, credentials: .password(session))
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.oauthBrowserURL = nil
                self.oauthFlow = nil
                self.connectError = (error as? HermesError)?.errorDescription
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
        oauthFlow = (listener, task)
    }

    /// Set when a gated server is OAuth-only but advertises `native_pkce`:
    /// the connect screen offers a browser sign-in.
    struct PendingOAuthLogin: Equatable {
        var endpoint: ServerEndpoint
        var providerName: String
        var providerDisplayName: String
    }
    private(set) var pendingOAuthLogin: PendingOAuthLogin?

    /// Look up the gated server's sign-in options; surface the password form
    /// when available, else the native-PKCE browser flow.
    private func presentGatedLogin(
        endpoint: ServerEndpoint, note: String? = nil, generation: Int? = nil
    ) async {
        let providers =
            (try? await HermesAuthenticator.authProviders(endpoint: endpoint)) ?? []
        if let generation, generation != connectGeneration { return }
        guard let passwordProvider = providers.first(where: \.supportsPassword) else {
            if serverStatus?.supportsNativePKCE == true, let provider = providers.first {
                pendingOAuthLogin = PendingOAuthLogin(
                    endpoint: endpoint,
                    providerName: provider.name,
                    providerDisplayName: provider.displayName)
                connectError = note
            } else {
                connectError =
                    "This server only offers browser (OAuth) sign-in without the native flow. Configure dashboard.basic_auth on the server for username/password access, or run it on loopback."
            }
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
        cancelOAuthFlow()
        stopPathMonitor()
        updatePump?.cancel()
        updatePump = nil
        let connection = connection
        self.connection = nil
        if let connection {
            Task { await connection.stop() }
        }
        phase = .stopped
        route = nil
        // Invalidate, don't just drop: ChatView's `.task` may still be on
        // its way to begin(), which must become a no-op rather than dial
        // RPCs against the stopped connection (#48's surviving race).
        activeChat?.invalidate()
        activeChat = nil
        profiles = []
        projectTree = nil
        recentSessions = []
        selectedProfile = nil
        contractNotice = nil
        keychainNotice = nil
        botModeSupported = nil
        sidebarTab = .sessions
        bots = []
        botsLoading = false
        botsError = nil
        botAvatars = [:]
        botAvatarFetchesInFlight = []
        lastBotsRefresh = nil
    }

    /// Immediate re-dial on foreground (backoff skip).
    func appBecameActive() {
        guard let connection else { return }
        Task { await connection.pokeReconnect() }
    }

    /// The unreachable banner's retry button.
    func retryConnection() {
        guard let connection else { return }
        Task { await connection.pokeReconnect() }
    }

    // MARK: Network-path watching

    private var pathMonitor: NWPathMonitor?

    /// Re-dial the moment the network comes back (or changes) instead of
    /// waiting out a backoff — a poke also restarts a given-up supervisor.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard let self, let connection = self.connection else { return }
                await connection.pokeReconnect()
            }
        }
        monitor.start(queue: DispatchQueue(label: "mercury.path-monitor"))
        pathMonitor = monitor
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    func requestNewSession(cwd: String? = nil) {
        guard isConnected else { return }
        route = .newSession(cwd: cwd)
    }

    // MARK: Session management (stored sessions, no resume needed)

    func renameSession(_ session: SessionSummary, to title: String) async {
        guard let connection else { return }
        // A session titled "Bot Chat" is (or is indistinguishable from) a
        // bot's canonical forever-chat — the gateway registry resolves by
        // that exact name, so renaming severs the bot relationship and the
        // next open mints a replacement. The sidebar hides Rename for these
        // rows; this covers any other caller.
        guard session.title != BotChatPolicy.canonicalTitle else {
            browseError =
                "That's a bot's canonical Bot Chat — its title is its identity and can't change."
            return
        }
        do {
            try await connection.rest.updateSession(
                storedID: session.storedID, title: title, profile: session.profile)
            await refreshProjects()
        } catch {
            browseError = (error as? HermesError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    func togglePin(_ session: SessionSummary) async {
        guard let connection else { return }
        try? await connection.rest.updateSession(
            storedID: session.storedID, pinned: !session.pinned, profile: session.profile)
        await refreshProjects()
    }

    func deleteSession(_ session: SessionSummary) async {
        guard let connection else { return }
        do {
            try await connection.rest.deleteSession(
                storedID: session.storedID, profile: session.profile)
            if case .session(let selected) = route, selected.storedID == session.storedID {
                route = nil
            }
            await refreshProjects()
        } catch {
            browseError = (error as? HermesError)?.errorDescription
                ?? error.localizedDescription
        }
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
                            // has earned a spot in the saved list. Persist the
                            // authenticator's LIVE credentials, not the pair
                            // connect() started with: the validation probe may
                            // have rotated tokens (401 → refresh), and writing
                            // the pre-rotation refresh token back strands the
                            // next launch on a token the server already burned
                            // — Nous reuse-detection then revokes the whole
                            // session, forcing a browser sign-in (#37).
                            let live = await connection.authenticator.credentials
                            self.persistValidatedServer(
                                endpoint: endpoint, credentials: live ?? credentials)
                            pendingSave = nil
                        }
                        if !isReconnect {
                            await self.loadBrowseData()
                        }
                        await self.activeChat?.connectionBecameReady(
                            isReconnect: isReconnect)
                    }
                    if case .authExpired = phase {
                        // Credentials are dead. Token mode: the ephemeral
                        // token died with a backend restart — ask for a fresh
                        // dashboard URL. Gated mode: re-run sign-in. Present
                        // BEFORE disconnect — disconnect cancels this pump.
                        if self.serverStatus?.authRequired == true,
                            let endpoint = self.endpoint
                        {
                            await self.presentGatedLogin(
                                endpoint: endpoint,
                                note: HermesError.sessionExpired.errorDescription)
                        } else {
                            self.connectError = HermesError.unauthorized.errorDescription
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
        if !tokenStore.setCredentials(credentials, for: endpoint) {
            keychainNotice = Self.keychainWriteFailureNotice
        }
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
            // Keep the visible roster's previews/ordering fresh; loadBots'
            // throttle absorbs the per-turn burst of these events.
            if sidebarTab == .bots {
                Task { await loadBots() }
            }
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
        // Bot Mode probe: once per connection (reconnects keep the verdict; a
        // transport-shaped failure leaves nil so the next connect re-probes).
        if botModeSupported == nil {
            Task {
                if let supported = await connection.probeBotModeSupport() {
                    botModeSupported = supported
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
            projectTree = try await connection.projectsTree(profile: selectedProfile)
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

    // MARK: Bot Mode roster

    /// Refresh the Bots roster. The full listing walks every profile's
    /// state.db, so refreshes within 5s of the last are dropped unless
    /// forced (pull-to-refresh).
    func loadBots(force: Bool = false) async {
        guard let connection, botModeSupported == true else { return }
        if !force, let last = lastBotsRefresh, Date().timeIntervalSince(last) < 5 {
            return
        }
        if botsLoading { return }
        botsLoading = true
        defer { botsLoading = false }
        lastBotsRefresh = Date()
        do {
            bots = try await connection.listBots()
            botsError = nil
        } catch {
            // Keep the stale roster visible; surface the failure alongside.
            botsError = (error as? HermesError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// Kick off the avatar fetch for a roster row when the server has one we
    /// haven't cached. Fire-and-forget from row `.task`s; failures just leave
    /// the geometric fallback face.
    func fetchBotAvatarIfNeeded(_ bot: BotSummary) {
        guard bot.hasAvatar, botAvatars[bot.name] == nil,
            !botAvatarFetchesInFlight.contains(bot.name),
            let connection
        else { return }
        botAvatarFetchesInFlight.insert(bot.name)
        Task {
            defer { botAvatarFetchesInFlight.remove(bot.name) }
            if let asset = try? await connection.profileAvatar(name: bot.name) {
                botAvatars[bot.name] = asset.data
            }
        }
    }

    /// A roster row's click target. The canonical chat's server-resolved
    /// live tip is read fresh from the row (never cached across opens);
    /// a bot with no canonical chat yet gets one created on open.
    func botChatTarget(for bot: BotSummary) -> BotChatTarget {
        BotChatTarget(
            profile: bot.name,
            displayTitle: bot.title,
            storedID: bot.canonicalSession?.resolvedID ?? bot.canonicalSession?.storedID)
    }

    /// Cheap probe for `desktop_contract` drift. The throwaway lazy session
    /// it needs lives in `probeDesktopContract()`, which guarantees the close
    /// (and retries it once) so a cancelled or failed probe can't leave a
    /// ghost session in the sidebar (issue #49).
    private func checkContractVersion() async {
        guard let connection, contractNotice == nil else { return }
        guard let contract = try? await connection.probeDesktopContract() else { return }
        if contract != GatewayClient.builtAgainstDesktopContract {
            contractNotice =
                "This server speaks desktop contract v\(contract); Mercury was built against v\(GatewayClient.builtAgainstDesktopContract). Most things should still work, but expect rough edges."
        }
    }
}
