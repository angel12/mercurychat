import ChatCore
import Foundation
import MercuryKit
import Testing

/// Issue #91: a reconnect replay parks sequenced live events while its
/// `session.events.since` fetch is in flight. A newer `begin` (a canonical
/// `/compact` resume, say) supersedes the replay, and the replay's cleanup
/// only ran while it still owned the begin generation — so it returned
/// without clearing its buffering, and every later sequenced event was
/// parked forever with nothing left to drain it: the transcript froze.
@Suite("Replay supersession", .timeLimit(.minutes(1)))
@MainActor
struct ReplaySupersessionTests {
    final class ResumeScript: @unchecked Sendable {
        func respond(method: String) -> JSONValue? {
            let info: JSONValue = ["desktop_contract": 8]
            switch method {
            case "session.create":
                return ["session_id": "rt-probe", "info": info]
            case "session.resume":
                return ["session_id": "rt-1", "stored_session_id": "stored-1", "info": info]
            case "session.events.since":
                return ["events": [], "latest_seq": 1, "truncated": false]
            default:
                return .object([:])
            }
        }
    }

    private func event(_ type: String, _ payload: JSONValue, seq: Int) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: "rt-1", payload: payload, seq: seq)
    }

    @Test func aSupersededReplayDoesNotBufferForever() async throws {
        let replayGate = TestReplyGate()
        let script = ResumeScript()
        let server = try await HermesTestServer.start(
            rpc: { method, _ in script.respond(method: method) },
            rpcHold: { method, _ in method == "session.events.since" ? replayGate : nil }
        ) { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": false}"#)
            default:
                return TestHTTPResponse(200, #"{"messages": []}"#)
            }
        }
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let model = AppModel(tokenStore: store)
        defer {
            replayGate.open()
            model.disconnect()
            server.stop()
            try? store.deleteToken(for: endpoint)
        }
        await model.connect(endpoint: endpoint, credentials: nil)
        let ready = await eventually {
            if case .ready = model.phase { return true }
            return false
        }
        try #require(ready)

        // A resumed session with a seq watermark, so a reconnect replays.
        let chat = try #require(model.openChat(profile: nil))
        let summary = try #require(SessionSummary(json: ["id": "stored-1"]))
        await chat.begin(.resume(summary))
        try #require(chat.runtimeID == "rt-1")
        chat.handle(event: event(GatewayEvent.Kind.sessionInfo, ["running": false], seq: 1))

        // Reconnect: the replay's gap fetch is held in flight.
        let replaying = Task { await chat.connectionBecameReady(isReconnect: true) }
        #expect(await replayGate.reached.wait(), "the replay never fetched its gap")

        let replies = {
            chat.store.items.compactMap { item -> String? in
                if case .assistant(let message) = item { return message.text }
                return nil
            }
        }
        func deliverTurn(_ text: String, from seq: Int) {
            chat.handle(event: event(GatewayEvent.Kind.messageStart, [:], seq: seq))
            chat.handle(event: event(GatewayEvent.Kind.messageDelta, ["text": .string(text)], seq: seq + 1))
            chat.handle(
                event: event(GatewayEvent.Kind.messageComplete, ["text": .string(text)], seq: seq + 2))
            chat.handle(event: event(GatewayEvent.Kind.sessionInfo, ["running": false], seq: seq + 3))
        }

        // A newer resume supersedes the replay and completes while the
        // replay's fetch is still out. A turn now belongs to the newer
        // resume, not to the superseded replay's buffer.
        await chat.begin(.resume(summary))
        deliverTurn("during the stale replay", from: 10)
        let landedEarly = await eventually(within: 2) { replies().contains("during the stale replay") }
        #expect(landedEarly, "a turn after the newer resume was parked: \(replies())")

        // The replay's fetch returns; a turn after that must land too.
        replayGate.open()
        await replaying.value
        deliverTurn("after the replay returned", from: 20)
        let landedLate = await eventually(within: 2) { replies().contains("after the replay returned") }
        #expect(landedLate, "a turn after the replay returned was parked: \(replies())")

        #expect(replies() == ["during the stale replay", "after the replay returned"])
        #expect(!chat.store.running)
    }
}
