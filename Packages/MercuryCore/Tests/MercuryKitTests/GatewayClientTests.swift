import Foundation
import Testing

@testable import MercuryKit

/// GatewayClient against a real local WebSocket server: connect handshake,
/// request/response correlation, event demux, and close-code mapping — the
/// wire behavior nothing exercised before.
@Suite("GatewayClient", .timeLimit(.minutes(1)))
struct GatewayClientTests {
    private static func client(port: UInt16) throws -> GatewayClient {
        GatewayClient(
            endpoint: try ServerEndpoint.parse("http://127.0.0.1:\(port)").endpoint,
            token: "test-token")
    }

    /// Poll until the condition holds (the socket callbacks land on
    /// background queues).
    private func eventually(
        _ condition: @Sendable () async -> Bool, within seconds: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test func connectCompletesOnGatewayReady() async throws {
        let server = try await LocalGatewayServer.start()
        defer { server.stop() }
        let client = try Self.client(port: server.port)

        try await client.connect()
        let state = await client.state
        #expect(state == .ready)
        await client.close()
    }

    @Test func connectTimesOutWithoutGatewayReady() async throws {
        // A server that accepts but never sends gateway.ready.
        let server = try await LocalGatewayServer.start(onOpen: { _ in })
        defer { server.stop() }
        let client = try Self.client(port: server.port)

        await #expect(throws: HermesError.self) {
            try await client.connect(timeout: 0.3)
        }
    }

    @Test func responsesCorrelateByIdAcrossConcurrentRequests() async throws {
        let server = try await LocalGatewayServer.start(onText: { text, server in
            // Answer OUT of order, correlating by the method each request
            // carried — the client must route by id, not arrival order.
            guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                let id = frame["id"]?.intValue,
                let method = frame["method"]?.stringValue
            else { return }
            if method == "slow.method" {
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    server.respond(id: id, result: #"{"which": "slow"}"#)
                }
            } else {
                server.respond(id: id, result: #"{"which": "fast"}"#)
            }
        })
        defer { server.stop() }
        let client = try Self.client(port: server.port)
        try await client.connect()

        async let slow = client.request("slow.method")
        async let fast = client.request("fast.method")
        let (slowResult, fastResult) = try await (slow, fast)

        #expect(slowResult["which"]?.stringValue == "slow")
        #expect(fastResult["which"]?.stringValue == "fast")
        await client.close()
    }

    @Test func errorResponsesSurfaceAsRPCErrors() async throws {
        let server = try await LocalGatewayServer.start(onText: { text, server in
            guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                let id = frame["id"]?.intValue
            else { return }
            server.respondError(id: id, code: HermesError.RPCCode.sessionBusy, message: "busy")
        })
        defer { server.stop() }
        let client = try Self.client(port: server.port)
        try await client.connect()

        do {
            _ = try await client.request("prompt.submit")
            Issue.record("expected rpcError")
        } catch HermesError.rpcError(let code, let message) {
            #expect(code == HermesError.RPCCode.sessionBusy)
            #expect(message == "busy")
        }
        await client.close()
    }

    @Test func serverEventsReachSubscribers() async throws {
        let server = try await LocalGatewayServer.start()
        defer { server.stop() }
        let client = try Self.client(port: server.port)
        try await client.connect()

        var events = await client.events().makeAsyncIterator()
        server.sendEvent(
            type: "message.delta", sessionID: "ab12", payload: #"{"text": "hi"}"#)

        let event = await events.next()
        #expect(event?.type == "message.delta")
        #expect(event?.sessionID == "ab12")
        #expect(event?.payload["text"]?.stringValue == "hi")
        await client.close()
    }

    @Test func serverClose4401MapsToUnauthorized() async throws {
        let server = try await LocalGatewayServer.start()
        defer { server.stop() }
        let client = try Self.client(port: server.port)
        try await client.connect()

        var events = await client.events().makeAsyncIterator()
        server.close(code: 4401)

        // The stream finishing is the disconnect signal…
        while await events.next() != nil {}
        // …and the close reason carries the supervisor's auth-stop marker.
        let closed = await eventually {
            if case .closed(let reason) = await client.state {
                return reason?.contains("(4401)") == true
            }
            return false
        }
        #expect(closed)
    }

    @Test func rejectedUpgradeMapsToUnauthorized() async throws {
        // The realistic auth-rejection path: the server answers the HTTP
        // upgrade itself with 401 (WS close codes never happen), and the
        // client must map it to the "(4401)" reason the supervisor's
        // auth-stop matches on.
        let server = try await ScriptedHTTPServer.start { _ in
            ScriptedHTTPResponse(401)
        }
        defer { server.stop() }
        let client = try Self.client(port: server.port)

        do {
            try await client.connect(timeout: 5)
            Issue.record("expected the upgrade to be rejected")
        } catch HermesError.connectionClosed(let reason) {
            #expect(reason?.contains("(4401)") == true)
        }
    }

    @Test func rejectedUpgrade403MapsToGuardRefusal() async throws {
        // A 403 on the HTTP upgrade is the Host/Origin guard, not bad
        // credentials — the reason must carry the "(4403)" marker the
        // supervisor's guard-stop matches on, never the "(4401)" one that
        // would prompt a pointless re-login.
        let server = try await ScriptedHTTPServer.start { _ in
            ScriptedHTTPResponse(403)
        }
        defer { server.stop() }
        let client = try Self.client(port: server.port)

        do {
            try await client.connect(timeout: 5)
            Issue.record("expected the upgrade to be refused")
        } catch HermesError.connectionClosed(let reason) {
            #expect(reason?.contains("(4403)") == true)
            #expect(reason?.contains("(4401)") != true)
        }
    }

    @Test func closeFinishesEventStreamsAndFailsPendingRequests() async throws {
        // A request in flight when the connection dies must throw, not hang.
        let server = try await LocalGatewayServer.start()
        defer { server.stop() }
        let client = try Self.client(port: server.port)
        try await client.connect()

        let hanging = Task { try await client.request("never.answered") }
        _ = await eventually { !server.receivedFrames.isEmpty }
        await client.close(reason: "test teardown")

        await #expect(throws: HermesError.self) { _ = try await hanging.value }
        var events = await client.events().makeAsyncIterator()
        #expect(await events.next() == nil)  // closed client: finished stream
    }
}
