import Foundation

/// Owns the lifecycle of a server connection: dial, stay connected, reconnect
/// with full-jitter exponential backoff, and republish gateway events across
/// socket generations as one stable stream.
///
/// Consumers watch `updates`; a `.phase(.ready(isReconnect: true))` element is
/// the cue to re-`session.resume` by **stored** id (runtime ids are recycled
/// across backend restarts).
public actor HermesConnection {
    public enum Phase: Sendable, Equatable {
        case disconnected(reason: String?)
        case connecting(attempt: Int)
        case ready(isReconnect: Bool)
        case stopped
        /// Password-mode refresh token is dead; redialing is pointless. The
        /// supervisor has stopped — the app must prompt for a fresh sign-in.
        case authExpired
    }

    public enum Update: Sendable {
        case phase(Phase)
        case event(GatewayEvent)
    }

    public nonisolated let endpoint: ServerEndpoint
    public nonisolated let authenticator: HermesAuthenticator
    public nonisolated let rest: HermesRESTClient

    public private(set) var phase: Phase = .stopped
    private var gateway: GatewayClient?
    private var supervisor: Task<Void, Never>?
    private var everConnected = false
    private var reconnectPoke: CheckedContinuation<Void, Never>?
    private var backoffTimer: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<Update>.Continuation] = [:]

    public init(endpoint: ServerEndpoint, authenticator: HermesAuthenticator) {
        self.endpoint = endpoint
        self.authenticator = authenticator
        self.rest = HermesRESTClient(endpoint: endpoint, authenticator: authenticator)
    }

    public init(endpoint: ServerEndpoint, token: String?) {
        self.init(
            endpoint: endpoint,
            authenticator: HermesAuthenticator(
                endpoint: endpoint,
                credentials: token.map { .sessionToken($0) }))
    }

    // MARK: Subscriptions

    public func updates() -> AsyncStream<Update> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(.phase(phase))
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func publish(_ update: Update) {
        if case .phase(let phase) = update { self.phase = phase }
        for sub in subscribers.values { sub.yield(update) }
    }

    // MARK: Lifecycle

    public func start() {
        guard supervisor == nil else { return }
        supervisor = Task { await runSupervisor() }
    }

    public func stop() {
        supervisor?.cancel()
        supervisor = nil
        backoffTimer?.cancel()
        backoffTimer = nil
        reconnectPoke?.resume()
        reconnectPoke = nil
        let gateway = gateway
        self.gateway = nil
        Task { await gateway?.close(reason: "stopped") }
        publish(.phase(.stopped))
    }

    /// Skip the current backoff delay — call on app-foreground or
    /// network-path change.
    public func pokeReconnect() {
        backoffTimer?.cancel()
        backoffTimer = nil
        reconnectPoke?.resume()
        reconnectPoke = nil
    }

    // MARK: RPC passthrough

    public func request(
        _ method: String, params: JSONValue? = nil, timeout: TimeInterval = 60
    ) async throws -> JSONValue {
        guard let gateway, case .ready = phase else { throw HermesError.notConnected }
        return try await gateway.request(method, params: params, timeout: timeout)
    }

    // MARK: Supervisor

    private func runSupervisor() async {
        var attempt = 0
        while !Task.isCancelled {
            publish(.phase(.connecting(attempt: attempt)))

            let client = GatewayClient(endpoint: endpoint, authenticator: authenticator)
            do {
                try await client.connect()
            } catch {
                await client.close(reason: nil)
                if Task.isCancelled { return }  // stop() already published .stopped
                if case HermesError.sessionExpired = error {
                    // The refresh token is dead — every redial would fail the
                    // same way. Stop; the user must sign in again.
                    publish(.phase(.authExpired))
                    supervisor = nil
                    return
                }
                let reason = (error as? HermesError)?.errorDescription ?? "\(error)"
                if Self.isCredentialRejection(reason) {
                    // 4401: the server actively rejected the credentials
                    // (revoked token / dead ticket). Redialing is a retry
                    // storm, not a recovery — stop and demand re-auth.
                    publish(.phase(.authExpired))
                    supervisor = nil
                    return
                }
                if Self.isGuardRejection(reason) {
                    // 4403: Host/Origin/peer guard — a configuration
                    // mismatch every redial will hit identically. Stop and
                    // leave the explanation on screen.
                    publish(.phase(.disconnected(reason: reason)))
                    supervisor = nil
                    return
                }
                publish(.phase(.disconnected(reason: reason)))
                attempt += 1
                await backoff(attempt: attempt)
                continue
            }

            // stop() during the handshake only sees the published `gateway`
            // (still nil here) — the local client must be closed explicitly
            // or its socket and receive loop outlive the connection.
            if Task.isCancelled {
                await client.close(reason: "stopped")
                return
            }

            gateway = client
            attempt = 0
            publish(.phase(.ready(isReconnect: everConnected)))
            everConnected = true

            // Pump this socket generation's events into the stable stream;
            // the event stream finishing is the disconnect signal.
            for await event in await client.events() {
                if Task.isCancelled { break }
                publish(.event(event))
            }
            gateway = nil
            if Task.isCancelled {
                await client.close(reason: "stopped")
                break
            }

            let reason = await closeReason(of: client)
            if let reason, Self.isCredentialRejection(reason) {
                publish(.phase(.authExpired))
                supervisor = nil
                return
            }
            if let reason, Self.isGuardRejection(reason) {
                publish(.phase(.disconnected(reason: reason)))
                supervisor = nil
                return
            }
            publish(.phase(.disconnected(reason: reason)))
            attempt += 1
            await backoff(attempt: attempt)
        }
    }

    /// A 4401 close means the server rejected the credentials outright —
    /// distinct from a network drop, and never fixed by redialing.
    private static func isCredentialRejection(_ reason: String) -> Bool {
        reason.contains("(4401)")
    }

    /// A 4403 close is the Host/Origin/loopback-peer guard.
    private static func isGuardRejection(_ reason: String) -> Bool {
        reason.contains("(4403)")
    }

    private func closeReason(of client: GatewayClient) async -> String? {
        if case .closed(let reason) = await client.state { return reason }
        return nil
    }

    /// Full-jitter exponential backoff:
    /// `delay = random() * min(15s, 300ms * 2^attempt)`, skippable via
    /// `pokeReconnect()`.
    private func backoff(attempt: Int) async {
        let cap = min(15.0, 0.3 * pow(2.0, Double(attempt)))
        let delay = Double.random(in: 0...cap)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            reconnectPoke = cont
            // The timer must die with the wait it belongs to: a stale timer
            // surviving a pokeReconnect() would resume the NEXT backoff's
            // continuation early and collapse the exponential delay.
            backoffTimer = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self.finishBackoff()
            }
        }
    }

    private func finishBackoff() {
        backoffTimer = nil
        reconnectPoke?.resume()
        reconnectPoke = nil
    }
}
