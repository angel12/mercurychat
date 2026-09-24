import ChatCore
import Foundation
import MercuryKit
import Testing

/// Issue #94: `open_requests` is the whole set of server requests a session
/// still waits on, but Chat only ever APPLIED it — a card whose request was
/// answered, cancelled or timed out while the socket was down (its
/// `request.cancel` is never re-sent) survived every later snapshot. MercuryKit
/// reads an absent field as `[]`, so only a snapshot that carries the field is
/// authority to withdraw cards; an absent or malformed one keeps them.
@Suite("Open-request reconciliation", .timeLimit(.minutes(1)))
@MainActor
struct OpenRequestReconcileTests {
    /// Scripted gateway; each answer can change between calls.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var resumeExtras: [String: JSONValue]
        private var replay: JSONValue = .object([:])
        private var runtime = "rt-1"

        init(resumeExtras: [String: JSONValue]) { self.resumeExtras = resumeExtras }

        func setResumeExtras(_ extras: [String: JSONValue]) { lock.withLock { resumeExtras = extras } }
        func setReplay(_ result: JSONValue) { lock.withLock { replay = result } }
        func setRuntime(_ id: String) { lock.withLock { runtime = id } }

        func respond(method: String) -> JSONValue? {
            lock.withLock {
                let info: JSONValue = ["desktop_contract": 8]
                switch method {
                case "session.create":
                    return ["session_id": "rt-probe", "info": info]
                case "session.resume":
                    var result: [String: JSONValue] = [
                        "session_id": .string(runtime), "stored_session_id": "stored-1", "info": info,
                    ]
                    for (key, value) in resumeExtras { result[key] = value }
                    return .object(result)
                case "session.events.since":
                    return replay
                default:
                    return .object([:])
                }
            }
        }
    }

    /// Holds the history page while the gate is armed.
    final class HistoryGate: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private let released = DispatchSemaphore(value: 0)
        func arm() { lock.withLock { armed = true } }
        func release() {
            let wasArmed = lock.withLock {
                defer { armed = false }
                return armed
            }
            if wasArmed { released.signal() }
        }
        func waitIfArmed() {
            guard lock.withLock({ armed }) else { return }
            _ = released.wait(timeout: .now() + 10)
        }
    }

    private struct Harness {
        var chat: ChatController
        var script: Script
        var gate: HistoryGate
        var summary: SessionSummary
        var cleanup: () -> Void
    }

    nonisolated private static func request(_ id: String, command: String = "ls") -> JSONValue {
        [
            "id": .string(id), "method": "approval",
            "params": ["session_id": "rt-1", "request_id": .string("ap-\(id)"), "command": .string(command)],
        ]
    }

    private static let oldID = "srq-aaaaaaaaaaa1"
    private static let newID = "srq-bbbbbbbbbbb1"

    /// Connect and resume "stored-1" with `firstResume`, which must leave
    /// the old approval on its card.
    private func open(firstResume: [String: JSONValue]) async throws -> Harness {
        let script = Script(resumeExtras: firstResume)
        let gate = HistoryGate()
        let server = try await HermesTestServer.start(
            rpc: { method, _ in script.respond(method: method) },
            replayEpoch: "e1"
        ) { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": false}"#)
            case ("GET", let path) where path.hasPrefix("/api/sessions/stored-1/messages"):
                gate.waitIfArmed()
                return TestHTTPResponse(200, #"{"messages": []}"#)
            default:
                return TestHTTPResponse(200, "{}")
            }
        }
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let model = AppModel(tokenStore: store)
        let cleanup = {
            gate.release()
            model.disconnect()
            server.stop()
            try? store.deleteToken(for: endpoint)
        }
        await model.connect(endpoint: endpoint, credentials: nil)
        let ready = await eventually {
            if case .ready = model.phase { return true }
            return false
        }
        guard ready, let chat = model.openChat(profile: nil) else {
            cleanup()
            throw CancellationError()
        }
        chat.handle(
            event: GatewayEvent(
                type: GatewayEvent.Kind.gatewayReady, sessionID: nil,
                payload: ["replay_epoch": "e1"]))
        let summary = try #require(SessionSummary(json: ["id": "stored-1"]))
        await chat.begin(.resume(summary))
        try #require(chat.runtimeID == "rt-1")
        try #require(chat.store.pendingApproval?.serverRequestID == Self.oldID)
        return Harness(chat: chat, script: script, gate: gate, summary: summary, cleanup: cleanup)
    }

    private func openWithOldCard() async throws -> Harness {
        try await open(firstResume: ["running": true, "open_requests": [Self.request(Self.oldID)]])
    }

    // MARK: Resume snapshot

    @Test func anEmptySnapshotWithdrawsAStaleCard() async throws {
        let harness = try await openWithOldCard()
        defer { harness.cleanup() }
        harness.script.setResumeExtras(["running": true, "open_requests": []])
        await harness.chat.begin(.resume(harness.summary))
        #expect(harness.chat.store.pendingApproval == nil, "a resolved approval survived the snapshot")
    }

    /// A backend that doesn't send the field says nothing about open requests.
    @Test func aSnapshotWithoutTheFieldKeepsTheCard() async throws {
        let harness = try await openWithOldCard()
        defer { harness.cleanup() }
        harness.script.setResumeExtras(["running": true])
        await harness.chat.begin(.resume(harness.summary))
        #expect(harness.chat.store.pendingApproval?.serverRequestID == Self.oldID)
    }

    /// A malformed list is unknown, not empty.
    @Test func aMalformedSnapshotKeepsTheCard() async throws {
        let harness = try await openWithOldCard()
        defer { harness.cleanup() }
        harness.script.setResumeExtras(["running": true, "open_requests": [["id": "srq-broken00001"]]])
        await harness.chat.begin(.resume(harness.summary))
        #expect(harness.chat.store.pendingApproval?.serverRequestID == Self.oldID)
    }

    @Test func aSnapshotListingAnotherRequestReplacesTheCard() async throws {
        let harness = try await openWithOldCard()
        defer { harness.cleanup() }
        harness.script.setResumeExtras([
            "running": true, "open_requests": [Self.request(Self.newID, command: "make")],
        ])
        // A clarify is also stale: the list's approval replacing the approval
        // card would hide a missing reconcile, a lone clarify would not.
        harness.chat.handle(
            event: GatewayEvent(
                serverRequest: ServerRequest(
                    id: "srq-ccccccccccc1", method: "clarify",
                    params: ["session_id": "rt-1", "question": "Which env?"])))
        try #require(harness.chat.store.pendingClarify != nil)

        await harness.chat.begin(.resume(harness.summary))
        #expect(harness.chat.store.pendingApproval?.serverRequestID == Self.newID)
        #expect(harness.chat.store.pendingClarify == nil, "a resolved clarify survived the snapshot")
    }

    /// The snapshot predates events that arrive while the history page is
    /// out (#109): a request opened live after it must survive the
    /// reconcile against a list that couldn't yet include it.
    @Test func aRequestOpenedLiveAfterTheSnapshotSurvives() async throws {
        let harness = try await openWithOldCard()
        defer { harness.cleanup() }
        harness.script.setResumeExtras(["running": true, "open_requests": []])
        // A new runtime id makes adoption observable, as in
        // ResumeSnapshotOrderingTests.
        harness.script.setRuntime("rt-2")
        harness.gate.arm()
        let chat = harness.chat
        let resuming = Task { await chat.begin(.resume(harness.summary)) }
        let adopted = await eventually { chat.runtimeID == "rt-2" }
        try #require(adopted, "resume never adopted its runtime")
        chat.handle(
            event: GatewayEvent(
                serverRequest: ServerRequest(
                    id: Self.newID, method: "approval",
                    params: ["session_id": "rt-2", "request_id": "ap-new", "command": "make"])))
        harness.gate.release()
        await resuming.value

        #expect(chat.store.pendingApproval?.serverRequestID == Self.newID, "the live request was reconciled away")
    }

    // MARK: Replay page

    /// Reach watermark 10 with the old card still open.
    private func openAtWatermark(resume: [String: JSONValue]) async throws -> Harness {
        let harness = try await openWithOldCard()
        harness.chat.handle(
            event: GatewayEvent(
                type: GatewayEvent.Kind.sessionInfo, sessionID: "rt-1", payload: ["running": true],
                seq: 10))
        harness.script.setResumeExtras(resume)
        return harness
    }

    /// A non-empty page, so the resume snapshot isn't applied and the
    /// page's own `open_requests` is the only reconcile.
    nonisolated private static func page(openRequests: [JSONValue]) -> JSONValue {
        [
            "events": [
                [
                    "type": "session.info", "session_id": "rt-1", "seq": 11,
                    "payload": ["running": true],
                ]
            ],
            "latest_seq": 11, "truncated": false, "count": 1, "epoch": "e1",
            "open_requests": .array(openRequests),
        ]
    }

    @Test func aLosslessReplayWithdrawsCardsItDoesNotList() async throws {
        let harness = try await openAtWatermark(resume: ["running": true, "open_requests": []])
        defer { harness.cleanup() }
        harness.script.setReplay(Self.page(openRequests: [Self.request(Self.newID, command: "make")]))
        await harness.chat.connectionBecameReady(isReconnect: true)
        #expect(harness.chat.store.pendingApproval?.serverRequestID == Self.newID)

        harness.script.setReplay(
            [
                "events": [
                    ["type": "session.info", "session_id": "rt-1", "seq": 12, "payload": ["running": true]]
                ],
                "latest_seq": 12, "truncated": false, "count": 1, "epoch": "e1", "open_requests": [],
            ])
        await harness.chat.connectionBecameReady(isReconnect: true)
        #expect(harness.chat.store.pendingApproval == nil, "a resolved approval survived the replay")
    }

    /// The typed replay page can't tell an absent field from an empty one;
    /// a backend whose resume doesn't send `open_requests` isn't reporting
    /// them at all, so its replay can't withdraw anything either.
    @Test func aReplayFromABackendWithoutTheFieldKeepsTheCard() async throws {
        let harness = try await openAtWatermark(resume: ["running": true])
        defer { harness.cleanup() }
        var page = Self.page(openRequests: []).objectValue ?? [:]
        page["open_requests"] = nil
        harness.script.setReplay(.object(page))
        await harness.chat.connectionBecameReady(isReconnect: true)
        #expect(harness.chat.store.pendingApproval?.serverRequestID == Self.oldID)
    }
}
