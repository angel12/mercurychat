import ChatCore
import Foundation
import MercuryKit
import Testing

/// Roster refreshes coalesce instead of dropping (#106): a refresh asked for
/// while an older `profiles.list` is in flight must not be lost, and a
/// post-write caller must see rows read after its write — never the older
/// read's pre-write rows.
@Suite("Bot Refresh Coalescing", .timeLimit(.minutes(1)))
@MainActor
struct BotRefreshCoalescingTests {
    /// Scripted gateway: one bot whose look is CAS-guarded by a revision.
    /// `@unchecked` because access is lock-guarded.
    final class GatewayScript: @unchecked Sendable {
        private let lock = NSLock()
        private var title = "Old"
        private var revision = 1
        private var holdNext: TestReplyGate?
        private var failNext = false

        /// Hold the next `profiles.list` reply (its rows are snapshotted when
        /// the request lands, so it answers with the state of that moment).
        func holdNextList() -> TestReplyGate {
            let gate = TestReplyGate()
            lock.withLock { holdNext = gate }
            return gate
        }

        /// Fail the next `profiles.list` with an RPC error.
        func failNextList() { lock.withLock { failNext = true } }

        /// Another device edits the look.
        func remoteEdit(title: String) {
            lock.withLock {
                self.title = title
                revision += 1
            }
        }

        func respond(method: String, params: JSONValue) -> JSONValue? {
            lock.withLock {
                switch method {
                case "profiles.list":
                    return [
                        "profiles": [
                            [
                                "name": "scout", "path": "/p",
                                "ui_meta": ["hermes-bots": ["title": .string(title)]],
                                "ui_meta_revisions": ["hermes-bots": .number(Double(revision))],
                            ]
                        ]
                    ]
                case "profiles.configure":
                    let expected = params["ui_meta_expected_revisions"]?["hermes-bots"]?.intValue
                    if let expected, expected != revision {
                        return ["ok": true, "applied": ["ui_meta": false, "ui_meta_conflicts": ["hermes-bots": true]]]
                    }
                    if let newTitle = params["ui_meta"]?["hermes-bots"]?["title"]?.stringValue {
                        title = newTitle
                    }
                    revision += 1
                    return ["ok": true, "applied": ["ui_meta": true]]
                default:
                    return [:]
                }
            }
        }

        func error(method: String) -> (Int, String)? {
            lock.withLock {
                guard method == "profiles.list", failNext else { return nil }
                failNext = false
                return (5000, "state.db is locked")
            }
        }

        func hold(method: String) -> TestReplyGate? {
            lock.withLock {
                guard method == "profiles.list", let gate = holdNext else { return nil }
                holdNext = nil
                return gate
            }
        }
    }

    private func connectedModel(
        _ script: GatewayScript
    ) async throws -> (AppModel, HermesTestServer, () -> Void) {
        let server = try await HermesTestServer.start(
            rpc: { method, params in script.respond(method: method, params: params) },
            rpcError: { method, _ in script.error(method: method) },
            rpcHold: { method, _ in script.hold(method: method) }
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
        await model.connect(endpoint: endpoint, credentials: nil)
        let ready = await eventually {
            if case .ready = model.phase { return true }
            return false
        }
        try #require(ready)
        try #require(await eventually { model.botModeSupported == true })
        await model.loadBots(force: true)
        try #require(model.bots.first?.metaTitle == "Old")
        return (
            model, server,
            {
                model.disconnect()
                server.stop()
                try? store.deleteToken(for: endpoint)
            }
        )
    }

    private func listCount(_ server: HermesTestServer) -> Int {
        server.rpcRequests.filter { $0.method == "profiles.list" }.count
    }

    /// Hold an older (pull-to-refresh) read, save a new title: the save's
    /// forced refresh must wait for a read that started after the write, and
    /// the older pre-write reply must not be what the roster ends up with.
    @Test func aPostWriteRefreshSeesPostWriteRows() async throws {
        let script = GatewayScript()
        let (model, server, cleanup) = try await connectedModel(script)
        defer { cleanup() }
        let baseline = listCount(server)
        let bot = try #require(model.bots.first)

        let gate = script.holdNextList()
        let staleRead = Task { await model.loadBots(force: true) }
        #expect(await gate.reached.wait())

        let save = Task { await model.saveBotLook(bot, title: "New") }
        try #require(
            await eventually { server.rpcRequests.contains { $0.method == "profiles.configure" } })
        gate.open()
        #expect(await save.value == nil)
        await staleRead.value

        // The save returned with the post-write row — title and the CAS
        // revision the next edit is armed with.
        #expect(model.bots.first?.metaTitle == "New")
        #expect(model.bots.first?.uiMetaRevision == 2)
        #expect(listCount(server) == baseline + 2)

        // So the next edit isn't a spurious "edited from another device".
        let next = try #require(model.bots.first)
        #expect(await model.saveBotLook(next, description: "Finds things out") == nil)
    }

    /// The same, with the forced caller checked to be still waiting while
    /// the older read is held — it must not return on the in-flight check.
    @Test func aForcedRefreshWaitsOutTheInFlightRead() async throws {
        let script = GatewayScript()
        let (model, server, cleanup) = try await connectedModel(script)
        defer { cleanup() }
        let baseline = listCount(server)

        let gate = script.holdNextList()
        let staleRead = Task { await model.loadBots(force: true) }
        #expect(await gate.reached.wait())
        script.remoteEdit(title: "Remote")

        let forcedReturned = TestLatch()
        let forced = Task {
            await model.loadBots(force: true)
            forcedReturned.signal()
        }
        #expect(await !forcedReturned.wait(within: 0.2))
        #expect(model.bots.first?.metaTitle == "Old")

        gate.open()
        await forced.value
        await staleRead.value
        #expect(model.bots.first?.metaTitle == "Remote")
        #expect(listCount(server) == baseline + 2)
    }

    /// A held read that FAILS still gives way to the queued re-read, whose
    /// success clears the error.
    @Test func aFailedInFlightReadStillRunsTheQueuedRefresh() async throws {
        let script = GatewayScript()
        let (model, server, cleanup) = try await connectedModel(script)
        defer { cleanup() }
        let baseline = listCount(server)

        script.failNextList()
        let gate = script.holdNextList()
        let failing = Task { await model.loadBots(force: true) }
        #expect(await gate.reached.wait())
        script.remoteEdit(title: "Remote")

        let forced = Task { await model.loadBots(force: true) }
        try? await Task.sleep(for: .milliseconds(100))
        gate.open()
        await forced.value
        await failing.value
        #expect(model.botsError == nil)
        #expect(model.bots.first?.metaTitle == "Remote")
        #expect(listCount(server) == baseline + 2)
    }

    /// Any number of refreshes asked for during one in-flight read coalesce
    /// into exactly one follow-up read.
    @Test func refreshesDuringAReadCoalesceIntoOne() async throws {
        let script = GatewayScript()
        let (model, server, cleanup) = try await connectedModel(script)
        defer { cleanup() }
        let baseline = listCount(server)

        let gate = script.holdNextList()
        let first = Task { await model.loadBots(force: true) }
        #expect(await gate.reached.wait())
        let followers = (0..<3).map { _ in Task { await model.loadBots(force: true) } }
        try? await Task.sleep(for: .milliseconds(100))
        gate.open()
        for follower in followers { await follower.value }
        await first.value
        #expect(listCount(server) == baseline + 2)
        #expect(!model.botsLoading)
    }

    /// A throttled event (sessions.changed right after a listing) isn't
    /// dropped: it earns one trailing refresh once the window passes, however
    /// many events arrived inside it.
    @Test func aThrottledRefreshGetsOneTrailingRead() async throws {
        let script = GatewayScript()
        let (model, server, cleanup) = try await connectedModel(script)
        defer { cleanup() }
        let baseline = listCount(server)

        script.remoteEdit(title: "Remote")
        await model.loadBots()
        await model.loadBots()
        #expect(listCount(server) == baseline)  // still throttled

        #expect(await eventually(within: 8) { model.bots.first?.metaTitle == "Remote" })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(listCount(server) == baseline + 1)
    }
}
