import Foundation
import Testing

@testable import MercuryKit

// MARK: - Fakes

/// Gateway that dials instantly and answers RPCs from a per-method script.
/// Every request is recorded so tests can assert the probe's cleanup really
/// reached the wire (issue #49: a throwaway session left unclosed is a ghost
/// in every client's sidebar).
private actor RPCScriptGateway: GatewayDialing {
    var state: GatewayClient.State = .idle
    private var eventContinuation: AsyncStream<GatewayEvent>.Continuation?

    private var responses: [String: [Result<JSONValue, Error>]] = [:]
    private(set) var requests: [(method: String, params: JSONValue?)] = []
    /// Continuations parked by `holdNextRequest` — released by `releaseHeld`.
    private var heldMethods: Set<String> = []
    private var held: [CheckedContinuation<Void, Never>] = []

    func script(_ method: String, _ results: [Result<JSONValue, Error>]) {
        responses[method, default: []].append(contentsOf: results)
    }

    /// Park the next request for `method` until `releaseHeld()` — lets a test
    /// cancel the caller while the RPC is in flight.
    func holdNextRequest(_ method: String) {
        heldMethods.insert(method)
    }

    func releaseHeld() {
        let waiting = held
        held = []
        for cont in waiting { cont.resume() }
    }

    func requestCount(of method: String) -> Int {
        requests.filter { $0.method == method }.count
    }

    func connect(timeout: TimeInterval) async throws {
        state = .ready
    }

    func events() -> AsyncStream<GatewayEvent> {
        AsyncStream { continuation in
            eventContinuation = continuation
        }
    }

    func request(
        _ method: String, params: JSONValue?, timeout: TimeInterval
    ) async throws -> JSONValue {
        requests.append((method, params))
        if heldMethods.remove(method) != nil {
            await withCheckedContinuation { held.append($0) }
        }
        guard var queue = responses[method], !queue.isEmpty else {
            throw HermesError.rpcError(
                code: HermesError.RPCCode.methodNotFound, message: "unscripted: \(method)")
        }
        let result = queue.removeFirst()
        responses[method] = queue
        return try result.get()
    }

    func close(reason: String?) {
        state = .closed(reason: reason)
        eventContinuation?.finish()
    }
}

// MARK: - Harness

private struct Harness {
    let connection: HermesConnection
    let gateway: RPCScriptGateway

    init() {
        let gateway = RPCScriptGateway()
        self.gateway = gateway
        self.connection = HermesConnection(
            endpoint: try! ServerEndpoint.parse("http://127.0.0.1:9999").endpoint,
            authenticator: HermesAuthenticator(
                endpoint: try! ServerEndpoint.parse("http://127.0.0.1:9999").endpoint,
                credentials: .sessionToken("t")),
            giveUpAfter: 120,
            now: { ProcessInfo.processInfo.systemUptime },
            sleeper: { _ in },
            makeClient: { _, _ in gateway })
    }

    /// Dial and wait for `.ready` so `request` stops throwing notConnected.
    func start() async {
        var updates = await connection.updates().makeAsyncIterator()
        await connection.start()
        while let update = await updates.next() {
            if case .phase(.ready) = update { return }
        }
    }
}

private func createResult(sessionID: String, contract: Int?) -> JSONValue {
    var info: [String: JSONValue] = ["lazy": .bool(true)]
    if let contract { info["desktop_contract"] = .number(Double(contract)) }
    return .object([
        "session_id": .string(sessionID),
        "info": .object(info),
    ])
}

/// Poll until `condition` holds — the probe's close runs in an unstructured
/// task, so tests must wait for it rather than assume ordering.
private func eventually(
    _ condition: @escaping () async -> Bool,
    timeout: TimeInterval = 5
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

// MARK: - Tests

@Suite("Desktop-contract probe", .timeLimit(.minutes(1)))
struct ContractProbeTests {
    @Test func returnsTheContractAndClosesTheThrowaway() async throws {
        let harness = Harness()
        await harness.gateway.script(
            "session.create", [.success(createResult(sessionID: "s1", contract: 5))])
        await harness.gateway.script("session.close", [.success(["closed": .bool(true)])])
        await harness.start()

        let contract = try await harness.connection.probeDesktopContract()

        #expect(contract == 5)
        #expect(await harness.gateway.requestCount(of: "session.close") == 1)
        let close = await harness.gateway.requests.last
        #expect(close?.params?["session_id"]?.stringValue == "s1")
    }

    @Test func missingContractStillCloses() async throws {
        // Older backend whose session.create info lacks the field: no verdict,
        // but the throwaway must still be cleaned up.
        let harness = Harness()
        await harness.gateway.script(
            "session.create", [.success(createResult(sessionID: "s1", contract: nil))])
        await harness.gateway.script("session.close", [.success(["closed": .bool(true)])])
        await harness.start()

        let contract = try await harness.connection.probeDesktopContract()

        #expect(contract == nil)
        #expect(await harness.gateway.requestCount(of: "session.close") == 1)
    }

    @Test func unconfirmedCloseIsRetriedOnce() async throws {
        let harness = Harness()
        await harness.gateway.script(
            "session.create", [.success(createResult(sessionID: "s1", contract: 6))])
        await harness.gateway.script(
            "session.close",
            [.success(.object([:])), .success(["closed": .bool(true)])])
        await harness.start()

        _ = try await harness.connection.probeDesktopContract()

        #expect(await harness.gateway.requestCount(of: "session.close") == 2)
    }

    @Test func failedCloseIsRetriedOnce() async throws {
        let harness = Harness()
        await harness.gateway.script(
            "session.create", [.success(createResult(sessionID: "s1", contract: 6))])
        await harness.gateway.script(
            "session.close",
            [.failure(HermesError.timeout("session.close")), .success(["closed": .bool(true)])])
        await harness.start()

        _ = try await harness.connection.probeDesktopContract()

        #expect(await harness.gateway.requestCount(of: "session.close") == 2)
    }

    @Test func retryStopsAfterOneAttempt() async throws {
        // Both closes fail: exactly two attempts (no retry storm), and the
        // probe still reports the contract — closeSession already logged the
        // leak for investigation.
        let harness = Harness()
        await harness.gateway.script(
            "session.create", [.success(createResult(sessionID: "s1", contract: 4))])
        await harness.gateway.script(
            "session.close",
            [
                .failure(HermesError.timeout("session.close")),
                .failure(HermesError.timeout("session.close")),
            ])
        await harness.start()

        let contract = try await harness.connection.probeDesktopContract()

        #expect(contract == 4)
        #expect(await harness.gateway.requestCount(of: "session.close") == 2)
    }

    @Test func createFailureThrowsWithoutClosing() async throws {
        // No session was created, so there is nothing to clean up — a
        // session.close here would be a spurious RPC against a random id.
        let harness = Harness()
        await harness.gateway.script(
            "session.create", [.failure(HermesError.timeout("session.create"))])
        await harness.start()

        await #expect(throws: HermesError.self) {
            _ = try await harness.connection.probeDesktopContract()
        }
        #expect(await harness.gateway.requestCount(of: "session.close") == 0)
    }

    @Test func cancellationBetweenCreateAndCloseStillCloses() async throws {
        // The exact leak from issue #49: the probing task dies after
        // session.create succeeded. The close must run anyway — it lives in
        // an unstructured task, outside the caller's cancellation scope.
        let harness = Harness()
        await harness.gateway.script(
            "session.create", [.success(createResult(sessionID: "s1", contract: 6))])
        await harness.gateway.script("session.close", [.success(["closed": .bool(true)])])
        await harness.start()

        await harness.gateway.holdNextRequest("session.create")
        let probe = Task { try await harness.connection.probeDesktopContract() }
        // Wait for create to be in flight, cancel the caller, then let the
        // create response through.
        #expect(
            await eventually({ await harness.gateway.requestCount(of: "session.create") == 1 }))
        probe.cancel()
        await harness.gateway.releaseHeld()
        _ = try? await probe.value

        #expect(
            await eventually({ await harness.gateway.requestCount(of: "session.close") == 1 }))
    }
}
