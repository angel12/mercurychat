import Foundation
import Testing

@testable import MercuryKit

// MARK: - Fakes

/// Monotonic fake clock: the injected sleeper advances it instantly, so
/// backoff-heavy supervisor tests run in microseconds.
private final class FakeTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func now() -> TimeInterval {
        lock.withLock { value }
    }

    func advance(by delta: TimeInterval) {
        lock.withLock { value += delta }
    }
}

/// Scripted dial results consumed one per supervisor attempt; `fallback`
/// answers once the script runs out (and can be flipped mid-test).
private final class DialScript: @unchecked Sendable {
    enum Step {
        case fail(Error)
        case succeed
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var fallbackStep: Step
    private var gateways: [FakeGateway] = []

    init(steps: [Step] = [], fallback: Step) {
        self.steps = steps
        self.fallbackStep = fallback
    }

    var dialCount: Int {
        lock.withLock { gateways.count }
    }

    var lastGateway: FakeGateway? {
        lock.withLock { gateways.last }
    }

    func setFallback(_ step: Step) {
        lock.withLock { fallbackStep = step }
    }

    func makeGateway() -> FakeGateway {
        lock.withLock {
            let step = steps.isEmpty ? fallbackStep : steps.removeFirst()
            let gateway = FakeGateway(step: step)
            gateways.append(gateway)
            return gateway
        }
    }
}

private actor FakeGateway: GatewayDialing {
    private let step: DialScript.Step
    var state: GatewayClient.State = .idle
    private var eventContinuation: AsyncStream<GatewayEvent>.Continuation?

    init(step: DialScript.Step) {
        self.step = step
    }

    func connect(timeout: TimeInterval) async throws {
        switch step {
        case .fail(let error):
            state = .closed(reason: (error as? HermesError)?.errorDescription)
            throw error
        case .succeed:
            state = .ready
        }
    }

    func events() -> AsyncStream<GatewayEvent> {
        AsyncStream { continuation in
            eventContinuation = continuation
        }
    }

    func request(
        _ method: String, params: JSONValue?, timeout: TimeInterval
    ) async throws -> JSONValue {
        throw HermesError.notConnected
    }

    func close(reason: String?) {
        state = .closed(reason: reason)
        eventContinuation?.finish()
    }

    /// Test hook: the server side drops the socket.
    func dropConnection(reason: String?) {
        state = .closed(reason: reason)
        eventContinuation?.finish()
    }
}

// MARK: - Harness

private struct Harness {
    let connection: HermesConnection
    let script: DialScript
    let time: FakeTime

    init(steps: [DialScript.Step] = [], fallback: DialScript.Step) {
        let script = DialScript(steps: steps, fallback: fallback)
        let time = FakeTime()
        self.script = script
        self.time = time
        self.connection = HermesConnection(
            endpoint: try! ServerEndpoint.parse("http://127.0.0.1:9999").endpoint,
            authenticator: HermesAuthenticator(
                endpoint: try! ServerEndpoint.parse("http://127.0.0.1:9999").endpoint,
                credentials: .sessionToken("t")),
            giveUpAfter: 120,
            now: { time.now() },
            sleeper: { delay in time.advance(by: delay) },
            makeClient: { _, _ in script.makeGateway() })
    }
}

/// Pull phase updates off the stream, skipping events, until one matches.
/// Returns every phase seen on the way (the match is last).
private func phases(
    upTo match: (HermesConnection.Phase) -> Bool,
    from iterator: inout AsyncStream<HermesConnection.Update>.AsyncIterator,
    limit: Int = 2000
) async -> [HermesConnection.Phase] {
    var seen: [HermesConnection.Phase] = []
    for _ in 0..<limit {
        guard let update = await iterator.next() else { break }
        guard case .phase(let phase) = update else { continue }
        seen.append(phase)
        if match(phase) { return seen }
    }
    return seen
}

private func isUnreachable(_ phase: HermesConnection.Phase) -> Bool {
    if case .unreachable = phase { return true }
    return false
}

// MARK: - Tests

@Suite("HermesConnection supervisor", .timeLimit(.minutes(1)))
struct HermesConnectionTests {
    @Test func givesUpAfterTheUnreachableWindow() async {
        let harness = Harness(fallback: .fail(HermesError.timeout("gateway.ready")))
        var updates = await harness.connection.updates().makeAsyncIterator()
        await harness.connection.start()

        let seen = await phases(upTo: isUnreachable, from: &updates)
        #expect(isUnreachable(seen.last ?? .stopped))
        // It genuinely retried before giving up (backoff sums to 120s of
        // fake time across many attempts, not one).
        #expect(harness.script.dialCount > 3)

        // The supervisor stopped: no further dials happen.
        let countAtGiveUp = harness.script.dialCount
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.script.dialCount == countAtGiveUp)
    }

    @Test func pokeReconnectRestartsAfterGiveUp() async {
        let harness = Harness(fallback: .fail(HermesError.timeout("gateway.ready")))
        var updates = await harness.connection.updates().makeAsyncIterator()
        await harness.connection.start()
        _ = await phases(upTo: isUnreachable, from: &updates)

        // The server is back; a poke (retry button, network-path change)
        // must restart the supervisor rather than being ignored.
        harness.script.setFallback(.succeed)
        await harness.connection.pokeReconnect()

        let seen = await phases(
            upTo: { $0 == .ready(isReconnect: false) }, from: &updates)
        #expect(seen.last == .ready(isReconnect: false))
    }

    @Test func readyResetsTheGiveUpWindow() async {
        let harness = Harness(steps: [.succeed], fallback: .succeed)
        var updates = await harness.connection.updates().makeAsyncIterator()
        await harness.connection.start()
        _ = await phases(upTo: { $0 == .ready(isReconnect: false) }, from: &updates)

        // A long healthy stretch, then the socket drops. The give-up window
        // must start at the NEW failure — a stale window from before the
        // connection would declare unreachable on the first hiccup.
        harness.time.advance(by: 500)
        await harness.script.lastGateway?.dropConnection(reason: nil)

        let seen = await phases(
            upTo: { $0 == .ready(isReconnect: true) }, from: &updates)
        #expect(seen.last == .ready(isReconnect: true))
        #expect(!seen.contains(where: isUnreachable))
    }

    @Test func transportErrorsPublishTheShortDescription() async {
        // A raw URLError stringifies to a multi-line NSError dump (UserInfo,
        // stream keys, failing URL) — that must never reach the banner.
        let harness = Harness(fallback: .fail(URLError(.cannotConnectToHost)))
        var updates = await harness.connection.updates().makeAsyncIterator()
        await harness.connection.start()

        let seen = await phases(
            upTo: { if case .disconnected = $0 { return true } else { return false } },
            from: &updates)
        guard case .disconnected(let reason)? = seen.last else {
            Issue.record("expected a disconnected phase")
            return
        }
        #expect(reason == URLError(.cannotConnectToHost).localizedDescription)
        #expect(reason?.contains("UserInfo") != true)
    }

    @Test func dialTime4401StopsWithAuthExpired() async {
        let harness = Harness(
            fallback: .fail(
                HermesError.connectionClosed(
                    "unauthorized (4401) — the server rejected the credentials")))
        var updates = await harness.connection.updates().makeAsyncIterator()
        await harness.connection.start()

        let seen = await phases(upTo: { $0 == .authExpired }, from: &updates)
        #expect(seen.last == .authExpired)
        #expect(harness.script.dialCount == 1)  // no retry storm
    }

    @Test func socketClose4401StopsWithAuthExpired() async {
        let harness = Harness(steps: [.succeed], fallback: .succeed)
        var updates = await harness.connection.updates().makeAsyncIterator()
        await harness.connection.start()
        _ = await phases(upTo: { $0 == .ready(isReconnect: false) }, from: &updates)

        await harness.script.lastGateway?.dropConnection(
            reason: "unauthorized (4401) — the server rejected the credentials")

        let seen = await phases(upTo: { $0 == .authExpired }, from: &updates)
        #expect(seen.last == .authExpired)
        #expect(harness.script.dialCount == 1)
    }
}
