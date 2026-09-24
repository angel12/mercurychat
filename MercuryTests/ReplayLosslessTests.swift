import ChatCore
import Foundation
import MercuryKit
import Testing

/// Issue #93: a reconnect replay is applied *instead of* a full re-hydrate,
/// so it must be provably every event after the watermark. Chat checked only
/// `truncated` and an optional epoch mismatch, and accepted an evicted ring
/// (empty, `truncated: false`, `latest_seq` below the watermark), holes,
/// frames for another session, malformed batches and a missing epoch. And
/// once it did fall back, the stale watermark survived the same-runtime
/// resume, so the renumbered events after it were silently dropped.
@Suite("Replay lossless gate", .timeLimit(.minutes(1)))
@MainActor
struct ReplayLosslessTests {
    final class Script: @unchecked Sendable {
        let replay: JSONValue
        init(replay: JSONValue) { self.replay = replay }

        func respond(method: String) -> JSONValue? {
            let info: JSONValue = ["desktop_contract": 8]
            switch method {
            case "session.create":
                return ["session_id": "rt-probe", "info": info]
            case "session.resume":
                return ["session_id": "rt-1", "stored_session_id": "stored-1", "info": info]
            case "session.events.since":
                return replay
            default:
                return .object([:])
            }
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    /// One replayed frame as the gateway sends it inside `events`.
    nonisolated private static func frame(
        _ seq: Int, _ type: String = GatewayEvent.Kind.sessionInfo,
        _ payload: JSONValue = ["running": false], session: String = "rt-1"
    ) -> JSONValue {
        ["type": .string(type), "session_id": .string(session), "seq": .number(Double(seq)),
         "payload": payload]
    }

    nonisolated private static func batch(
        _ events: [JSONValue], latest: Int, epoch: String? = "e1", count: Int? = nil
    ) -> JSONValue {
        var result: [String: JSONValue] = [
            "events": .array(events), "latest_seq": .number(Double(latest)),
            "truncated": false, "count": .number(Double(count ?? events.count)),
        ]
        if let epoch { result["epoch"] = .string(epoch) }
        return .object(result)
    }

    /// An unsafe replay answer, and whether `gateway.ready` taught the
    /// controller an epoch before the drop.
    struct UnsafeCase: CustomTestStringConvertible, Sendable {
        var name: String
        var replay: JSONValue
        var knownEpoch: String? = "e1"
        /// Resumes in all: the initial one, the replay's rebind (skipped when
        /// there is no epoch to replay under), and the full-path fallback.
        var resumes: Int { knownEpoch == nil ? 2 : 3 }
        var testDescription: String { name }
    }

    nonisolated static let unsafeCases: [UnsafeCase] = [
        // Ring evicted: the counter restarts at 1 and `truncated` reads false
        // because the ring is simply gone. latest_seq 0 < watermark 10.
        UnsafeCase(name: "evicted ring", replay: batch([], latest: 0)),
        UnsafeCase(name: "seq gap", replay: batch([frame(11), frame(13)], latest: 13)),
        UnsafeCase(name: "missing tail", replay: batch([frame(11)], latest: 12)),
        UnsafeCase(
            name: "other session", replay: batch([frame(11, session: "rt-other")], latest: 11)),
        UnsafeCase(
            name: "count mismatch", replay: batch([frame(11)], latest: 11, count: 2)),
        UnsafeCase(name: "mismatched epoch", replay: batch([frame(11)], latest: 11, epoch: "e2")),
        UnsafeCase(name: "missing batch epoch", replay: batch([frame(11)], latest: 11, epoch: nil)),
        UnsafeCase(
            name: "no known epoch", replay: batch([frame(11)], latest: 11), knownEpoch: nil),
    ]

    @MainActor private struct Harness {
        var chat: ChatController
        var server: HermesTestServer
        var historyFetches: Counter
        /// History-handler hits from the initial resume. A baseline, not 1:
        /// the scripted server can run its HTTP handler more than once per
        /// request (it re-parses the kept buffer on a later receive).
        var fetchesBeforeDrop = 0
        var cleanup: () -> Void

        var refetchedHistory: Bool { historyFetches.count > fetchesBeforeDrop }

        var resumes: Int { server.rpcRequests.filter { $0.method == "session.resume" }.count }

        func replies() -> [String] {
            chat.store.items.compactMap { item -> String? in
                if case .assistant(let message) = item { return message.text }
                return nil
            }
        }

        func deliverTurn(_ text: String, from seq: Int) {
            func event(_ type: String, _ payload: JSONValue, _ seq: Int) -> GatewayEvent {
                GatewayEvent(type: type, sessionID: "rt-1", payload: payload, seq: seq)
            }
            chat.handle(event: event(GatewayEvent.Kind.messageStart, [:], seq))
            chat.handle(event: event(GatewayEvent.Kind.messageDelta, ["text": .string(text)], seq + 1))
            chat.handle(
                event: event(GatewayEvent.Kind.messageComplete, ["text": .string(text)], seq + 2))
            chat.handle(event: event(GatewayEvent.Kind.sessionInfo, ["running": false], seq + 3))
        }
    }

    /// Resume "stored-1", reach watermark 10, then reconnect against `replay`.
    private func reconnect(replay: JSONValue, knownEpoch: String?) async throws -> Harness {
        let script = Script(replay: replay)
        let historyFetches = Counter()
        let server = try await HermesTestServer.start(
            rpc: { method, _ in script.respond(method: method) }
        ) { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": false}"#)
            case ("GET", let path) where path.hasPrefix("/api/sessions/stored-1/messages"):
                historyFetches.bump()
                return TestHTTPResponse(200, #"{"messages": []}"#)
            default:
                return TestHTTPResponse(200, "{}")
            }
        }
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let model = AppModel(tokenStore: store)
        let cleanup = {
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
        if let knownEpoch {
            chat.handle(
                event: GatewayEvent(
                    type: GatewayEvent.Kind.gatewayReady, sessionID: nil,
                    payload: ["replay_epoch": .string(knownEpoch)]))
        }
        let summary = try #require(SessionSummary(json: ["id": "stored-1"]))
        await chat.begin(.resume(summary))
        var harness = Harness(
            chat: chat, server: server, historyFetches: historyFetches, cleanup: cleanup)
        try #require(chat.runtimeID == "rt-1")
        try #require(harness.resumes == 1)
        harness.fetchesBeforeDrop = historyFetches.count
        try #require(harness.fetchesBeforeDrop >= 1)
        harness.deliverTurn("before the drop", from: 7)
        try #require(await eventually(within: 2) { harness.replies() == ["before the drop"] })

        await chat.connectionBecameReady(isReconnect: true)
        return harness
    }

    @Test(arguments: unsafeCases)
    func anUnsafeReplayFallsBackAndKeepsLaterEvents(_ unsafe: UnsafeCase) async throws {
        let harness = try await reconnect(replay: unsafe.replay, knownEpoch: unsafe.knownEpoch)
        defer { harness.cleanup() }

        // Fallback = the full path: another resume after any replay rebind,
        // and an authoritative history re-fetch.
        #expect(harness.resumes == unsafe.resumes, "replay was accepted instead of falling back")
        #expect(harness.refetchedHistory, "no authoritative re-hydrate")

        // The same runtime came back with (possibly) fresh numbering: the old
        // watermark must not swallow its low seqs.
        harness.deliverTurn("after the fallback", from: 1)
        let landed = await eventually(within: 2) {
            harness.replies().contains("after the fallback")
        }
        #expect(landed, "a low-seq event after fallback was dropped: \(harness.replies())")
    }

    /// Control: a provably complete batch is still replayed, not re-hydrated.
    @Test func aLosslessReplayIsApplied() async throws {
        let text: JSONValue = ["text": "while away"]
        let replay = Self.batch(
            [
                Self.frame(11, GatewayEvent.Kind.messageStart, [:]),
                Self.frame(12, GatewayEvent.Kind.messageDelta, text),
                Self.frame(13, GatewayEvent.Kind.messageComplete, text),
                Self.frame(14),
            ], latest: 14)
        let harness = try await reconnect(replay: replay, knownEpoch: "e1")
        defer { harness.cleanup() }

        #expect(harness.resumes == 2)
        #expect(!harness.refetchedHistory)
        let landed = await eventually(within: 2) {
            harness.replies() == ["before the drop", "while away"]
        }
        #expect(landed, "replayed turn missing: \(harness.replies())")
        // The watermark advanced to the replay's tail: a duplicate is dropped.
        harness.deliverTurn("duplicate", from: 11)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!harness.replies().contains("duplicate"))
    }
}
