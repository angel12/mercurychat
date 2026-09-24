import ChatCore
import Foundation
import MercuryKit
import Testing

/// Issue #94: `open_requests` is the whole set of server requests a session
/// still waits on, but Chat only ever APPLIED it — a card whose request was
/// answered, cancelled or timed out while the socket was down (its
/// `request.cancel` is never re-sent) survived every later snapshot. MercuryKit
/// reads an absent field as `[]`, so a list is authority to withdraw cards only
/// when it is present, or the backend is contract >= 7 (whose resume omits an
/// empty list and whose replay always sends one). A malformed list keeps them.
@Suite("Open-request reconciliation", .timeLimit(.minutes(1)))
@MainActor
struct OpenRequestReconcileTests {
    /// Scripted gateway; each answer can change between calls.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var resumeExtras: [String: JSONValue]
        private var replay: JSONValue = .object([:])
        private var runtime = "rt-1"
        private let contract: Int?

        init(resumeExtras: [String: JSONValue], contract: Int?) {
            self.resumeExtras = resumeExtras
            self.contract = contract
        }

        func setResumeExtras(_ extras: [String: JSONValue]) { lock.withLock { resumeExtras = extras } }
        func setReplay(_ result: JSONValue) { lock.withLock { replay = result } }
        func setRuntime(_ id: String) { lock.withLock { runtime = id } }

        func respond(method: String) -> JSONValue? {
            lock.withLock {
                let info: JSONValue =
                    contract.map { ["desktop_contract": .number(Double($0))] } ?? .object([:])
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
    private func open(firstResume: [String: JSONValue], contract: Int?) async throws -> Harness {
        let script = Script(resumeExtras: firstResume, contract: contract)
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

    private func openWithOldCard(contract: Int? = 8) async throws -> Harness {
        try await open(
            firstResume: ["running": true, "open_requests": [Self.request(Self.oldID)]],
            contract: contract)
    }

    // MARK: Resume snapshot

    /// An explicit list is authority on its own, whatever the contract.
    @Test(arguments: [8, nil] as [Int?])
    func anEmptySnapshotWithdrawsAStaleCard(contract: Int?) async throws {
        let harness = try await openWithOldCard(contract: contract)
        defer { harness.cleanup() }
        harness.script.setResumeExtras(["running": true, "open_requests": []])
        await harness.chat.begin(.resume(harness.summary))
        #expect(harness.chat.store.pendingApproval == nil, "a resolved approval survived the snapshot")
    }

    /// The real wire shape: a contract-7 gateway omits `open_requests` when
    /// nothing is open (`_live_session_payload` drops empty keys), so there
    /// its absence means empty. A backend below contract 7 — or one that
    /// reports none — doesn't replay requests at all, so absence says
    /// nothing and the card stays.
    @Test(arguments: [(8, true), (7, true), (6, false), (nil, false)] as [(Int?, Bool)])
    func aSnapshotWithoutTheField(contract: Int?, withdraws: Bool) async throws {
        let harness = try await openWithOldCard(contract: contract)
        defer { harness.cleanup() }
        harness.script.setResumeExtras(["running": true])
        await harness.chat.begin(.resume(harness.summary))
        if withdraws {
            #expect(harness.chat.store.pendingApproval == nil, "a resolved approval survived the snapshot")
        } else {
            #expect(harness.chat.store.pendingApproval?.serverRequestID == Self.oldID)
        }
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
        // Nothing open: the contract-8 gateway omits the field.
        harness.script.setResumeExtras(["running": true])
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
    private func openAtWatermark(
        resume: [String: JSONValue], contract: Int? = 8
    ) async throws -> Harness {
        let harness = try await openWithOldCard(contract: contract)
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
        let harness = try await openAtWatermark(resume: ["running": true])
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

    /// `session.events.since` always sends `open_requests` from contract 7,
    /// and the typed page reads an absent field as `[]`: only the contract
    /// makes an empty page's list authoritative. The resume just before
    /// omits the field (nothing open), as the real gateway does.
    @Test(arguments: [(8, true), (6, false), (nil, false)] as [(Int?, Bool)])
    func anEmptyLosslessReplay(contract: Int?, withdraws: Bool) async throws {
        let harness = try await openAtWatermark(resume: ["running": true], contract: contract)
        defer { harness.cleanup() }
        harness.script.setReplay(Self.page(openRequests: []))
        await harness.chat.connectionBecameReady(isReconnect: true)
        if withdraws {
            #expect(harness.chat.store.pendingApproval == nil, "a resolved approval survived the replay")
        } else {
            #expect(harness.chat.store.pendingApproval?.serverRequestID == Self.oldID)
        }
    }
}
