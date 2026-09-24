import Foundation
import MercuryKit
import Testing

/// Issue #95: the sidebar's browse and Bot state is fetched by requests that
/// suspend, and nothing tied a response to the connection, profile, or
/// request that sent it. A slow answer from server A landed on server B's
/// sidebar; a refresh started under profile P1 painted P1's tree over P2 (and
/// paired it with P2's recents) and cleared P2's spinner; and the first load
/// fetched every profile's sessions while the picker showed the default one.
@Suite("AppModel browse scoping", .timeLimit(.minutes(1)))
@MainActor
struct AppModelBrowseScopingTests {
    /// Holds one scripted HTTP answer until the test releases it.
    final class RequestHold: @unchecked Sendable {
        let reached = TestLatch()
        private let released = DispatchSemaphore(value: 0)
        func release() { released.signal() }
        func wait() {
            reached.signal()
            _ = released.wait(timeout: .now() + 10)
        }
    }

    /// A cross-thread on/off switch for a script.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        func signal() { lock.withLock { on = true } }
        var isSet: Bool { lock.withLock { on } }
    }

    /// Lock-guarded scripted state shared with the server's queues.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var gates: [String: TestReplyGate] = [:]
        private var queries: [String] = []

        /// The next reply keyed `key` waits on `gate`.
        func hold(_ key: String, on gate: TestReplyGate) { lock.withLock { gates[key] = gate } }
        func take(_ key: String) -> TestReplyGate? { lock.withLock { gates.removeValue(forKey: key) } }

        func record(_ query: String) { lock.withLock { queries.append(query) } }
        var recentsQueries: [String] { lock.withLock { queries } }
    }

    /// `projects.tree`, one project named after the profile it was asked for.
    nonisolated static func tree(for profile: String) -> JSONValue {
        .object(["projects": .array([.object(["id": .string("proj-\(profile)"), "name": .string("\(profile)-project")])])])
    }

    /// `/api/profiles/sessions`, one session named after the queried profile.
    nonisolated static func recents(query: String) -> String {
        let profile = query.split(separator: "&")
            .first { $0.hasPrefix("profile=") }
            .map { String($0.dropFirst("profile=".count)) } ?? "?"
        return #"{"sessions": [{"session_id": "s-\#(profile)", "title": "\#(profile)-session", "profile": "\#(profile)"}]}"#
    }

    nonisolated static let twoProfiles =
        #"{"profiles": [{"name": "p1", "is_default": true}, {"name": "p2"}]}"#

    /// Snapshots the defaults a validated connect writes, and removes any
    /// credentials the fixtures saved.
    private func isolate(_ endpoints: [ServerEndpoint], store: KeychainTokenStore) -> () -> Void {
        let prior = ["lastServer", "savedServers"].map {
            ($0, UserDefaults.standard.object(forKey: $0))
        }
        return {
            for endpoint in endpoints { try? store.deleteToken(for: endpoint) }
            for (key, value) in prior {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
    }

    private func endpoint(_ server: HermesTestServer) throws -> ServerEndpoint {
        try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
    }

    private func connectAndWaitReady(_ model: AppModel, _ endpoint: ServerEndpoint) async throws {
        await model.connect(endpoint: endpoint, credentials: .sessionToken("synthetic"))
        let ready = await eventually { model.phase == .ready(isReconnect: false) }
        try #require(ready, "never reached ready (phase: \(model.phase))")
    }

    // MARK: Across servers

    /// A's slow profile list answers after the user switched to B: B keeps
    /// its own (still loading) picker, and A's late finish doesn't end B's
    /// spinner.
    @Test func aSlowProfileListCannotLandOnTheNextServer() async throws {
        let holdA = RequestHold()
        let holdB = RequestHold()
        let serverA = try await HermesTestServer.start { request in
            switch request.path {
            case "/api/status": return TestHTTPResponse(200, #"{"auth_required": false}"#)
            case "/api/profiles":
                holdA.wait()
                return TestHTTPResponse(200, #"{"profiles": [{"name": "a-default", "is_default": true}]}"#)
            default: return TestHTTPResponse(200)
            }
        }
        defer { serverA.stop() }
        let serverB = try await HermesTestServer.start { request in
            switch request.path {
            case "/api/status": return TestHTTPResponse(200, #"{"auth_required": false}"#)
            case "/api/profiles":
                holdB.wait()
                return TestHTTPResponse(200, #"{"profiles": [{"name": "b-default", "is_default": true}]}"#)
            default: return TestHTTPResponse(200)
            }
        }
        defer { serverB.stop() }

        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let endpointA = try endpoint(serverA)
        let endpointB = try endpoint(serverB)
        let restore = isolate([endpointA, endpointB], store: store)
        defer {
            holdA.release()
            holdB.release()
            restore()
        }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        try await connectAndWaitReady(model, endpointA)
        #expect(await holdA.reached.wait(), "A's profile list was never requested")

        try await connectAndWaitReady(model, endpointB)
        #expect(await holdB.reached.wait(), "B's profile list was never requested")

        holdA.release()
        try? await Task.sleep(for: .milliseconds(400))
        #expect(model.profiles.isEmpty, "A's profiles populated B's picker")
        #expect(model.selectedProfile == nil, "A's default profile was selected on B")
        #expect(model.profilesLoading, "A's late finish cleared B's loading state")

        holdB.release()
        #expect(await eventually { model.selectedProfile == "b-default" })
        #expect(model.profiles.map(\.name) == ["b-default"])
        #expect(!model.profilesLoading)
    }

    /// A's contract probe resolves (its session close failing as A's socket
    /// goes away) after the switch: A's old-backend warning must not show
    /// on B.
    @Test func aStaleContractProbeCannotWarnOnTheNextServer() async throws {
        let closeGate = TestReplyGate()
        let serverA = try await HermesTestServer.start(
            rpc: { method, _ in
                method == "session.create"
                    ? .object(["session_id": "rt-a", "info": .object(["desktop_contract": 5])]) : nil
            },
            rpcHold: { method, _ in method == "session.close" ? closeGate : nil }
        ) { request in
            request.path == "/api/status"
                ? TestHTTPResponse(200, #"{"auth_required": false}"#) : TestHTTPResponse(200)
        }
        defer { serverA.stop() }
        let serverB = try await HermesTestServer.start { request in
            request.path == "/api/status"
                ? TestHTTPResponse(200, #"{"auth_required": false}"#) : TestHTTPResponse(200)
        }
        defer { serverB.stop() }

        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let endpointA = try endpoint(serverA)
        let endpointB = try endpoint(serverB)
        let restore = isolate([endpointA, endpointB], store: store)
        defer {
            closeGate.open()
            restore()
        }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        try await connectAndWaitReady(model, endpointA)
        #expect(await closeGate.reached.wait(), "A's contract probe never closed its session")

        try await connectAndWaitReady(model, endpointB)
        closeGate.open()
        try? await Task.sleep(for: .milliseconds(400))
        #expect(model.contractNotice == nil, "A's contract warning appeared on B")
    }

    /// A bot created on A whose look write (or the roster refresh after
    /// it) is still out when the user switches to B must not open a Bot
    /// Chat on B.
    @Test(arguments: ["profiles.configure", "profiles.list"])
    func aBotCreatedOnTheOldServerOpensNoChatOnTheNextOne(heldMethod: String) async throws {
        let configureGate = TestReplyGate()
        let serverA = try await HermesTestServer.start(
            rpc: { method, params in
                guard method == "profiles.create" else { return nil }
                let name = params["name"]?.stringValue ?? ""
                return .object([
                    "ok": true, "name": .string(name), "path": .string("/p/\(name)"),
                    "soul_written": true, "model_set": false,
                    "mirrored": ["env": true, "auth": "shared", "model_inherited": true, "voice": false],
                ])
            },
            rpcHold: { method, params in
                // `profiles.list` without sessions is the Bot Mode probe;
                // the roster listing is the one with them.
                guard method == heldMethod else { return nil }
                if method == "profiles.list", params["include_sessions"] != true { return nil }
                return configureGate
            }
        ) { request in
            request.path == "/api/status"
                ? TestHTTPResponse(200, #"{"auth_required": false}"#) : TestHTTPResponse(200)
        }
        defer { serverA.stop() }
        let serverB = try await HermesTestServer.start { request in
            request.path == "/api/status"
                ? TestHTTPResponse(200, #"{"auth_required": false}"#) : TestHTTPResponse(200)
        }
        defer { serverB.stop() }

        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let endpointA = try endpoint(serverA)
        let endpointB = try endpoint(serverB)
        let restore = isolate([endpointA, endpointB], store: store)
        defer {
            configureGate.open()
            restore()
        }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        try await connectAndWaitReady(model, endpointA)
        try #require(await eventually { model.botModeSupported == true })

        // Unregistered, so the connect to B (which empties registered windows)
        // can't mask a missing generation guard.
        let window = WindowNavigation()
        let creating = Task {
            await model.createBot(name: "Scout", title: "", description: "", openIn: window)
        }
        #expect(await configureGate.reached.wait(), "createBot never sent \(heldMethod)")

        try await connectAndWaitReady(model, endpointB)
        configureGate.open()
        _ = await creating.value
        #expect(window.route == nil, "A's new bot opened a Bot Chat on B")
        // A's roster listing died with A's socket; that failure isn't B's.
        #expect(model.botsError == nil, "A's roster failure showed on B")
    }

    /// A refresh still out at a disconnect: its recents (REST, which
    /// outlives the socket) answering late, or its tree RPC failing as the
    /// socket closes. Either way the connect screen's model stays empty and
    /// error-free.
    @Test(arguments: [false, true])
    func aRefreshOutlivingADisconnectPublishesNothing(holdTree: Bool) async throws {
        let recentsHold = RequestHold()
        let treeGate = TestReplyGate()
        let armed = Flag()
        let server = try await HermesTestServer.start(
            rpc: { method, _ in method == "projects.tree" ? Self.tree(for: "p1") : nil },
            rpcHold: { method, _ in
                holdTree && armed.isSet && method == "projects.tree" ? treeGate : nil
            }
        ) { request in
            switch request.path {
            case "/api/status": return TestHTTPResponse(200, #"{"auth_required": false}"#)
            case "/api/profiles/sessions":
                if !holdTree, armed.isSet { recentsHold.wait() }
                return TestHTTPResponse(200, Self.recents(query: request.query))
            default: return TestHTTPResponse(200)
            }
        }
        defer { server.stop() }

        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let endpoint = try endpoint(server)
        let restore = isolate([endpoint], store: store)
        defer {
            recentsHold.release()
            treeGate.open()
            restore()
        }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        try await connectAndWaitReady(model, endpoint)
        try #require(await eventually { !model.browseLoading && model.projectTree != nil })

        armed.signal()
        let refreshing = Task { await model.refreshProjects() }
        let inFlight = holdTree ? treeGate.reached : recentsHold.reached
        #expect(await inFlight.wait(), "the refresh never reached the held request")
        model.disconnect()
        recentsHold.release()
        await refreshing.value

        #expect(model.projectTree == nil, "a dead connection's tree was published")
        #expect(model.recentSessions.isEmpty, "a dead connection's recents were published")
        #expect(model.browseError == nil, "a dead connection's failure was published")
    }

    // MARK: Across profiles

    /// A refresh started under P1 finishes after the user picked P2: P2's
    /// sidebar stays empty and loading until P2's own refresh lands, and is
    /// never a mix of P1's tree and P2's recents.
    @Test func aRefreshForTheOldProfileCannotPaintTheNewOne() async throws {
        let script = Script()
        let server = try await HermesTestServer.start(
            rpc: { method, params in
                method == "projects.tree"
                    ? Self.tree(for: params["profile"]?.stringValue ?? "all") : nil
            },
            rpcHold: { method, params in
                method == "projects.tree"
                    ? script.take(params["profile"]?.stringValue ?? "all") : nil
            }
        ) { request in
            switch request.path {
            case "/api/status": return TestHTTPResponse(200, #"{"auth_required": false}"#)
            case "/api/profiles": return TestHTTPResponse(200, Self.twoProfiles)
            case "/api/profiles/sessions":
                return TestHTTPResponse(200, Self.recents(query: request.query))
            default: return TestHTTPResponse(200)
            }
        }
        defer { server.stop() }

        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let endpoint = try endpoint(server)
        let restore = isolate([endpoint], store: store)
        let p1Gate = TestReplyGate()
        let p2Gate = TestReplyGate()
        defer {
            p1Gate.open()
            p2Gate.open()
            restore()
        }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        try await connectAndWaitReady(model, endpoint)
        try #require(
            await eventually {
                model.selectedProfile == "p1" && !model.browseLoading && model.projectTree != nil
            })

        script.hold("p1", on: p1Gate)
        let staleRefresh = Task { await model.refreshProjects() }
        #expect(await p1Gate.reached.wait(), "the P1 refresh never asked for its tree")

        script.hold("p2", on: p2Gate)
        let switching = Task { await model.selectProfile("p2") }
        #expect(await p2Gate.reached.wait(), "the P2 refresh never asked for its tree")

        p1Gate.open()
        await staleRefresh.value
        #expect(model.projectTree == nil, "P1's tree painted P2's sidebar")
        #expect(model.recentSessions.isEmpty, "P1's refresh published recents under P2")
        #expect(model.browseLoading, "P1's refresh cleared P2's loading state")

        p2Gate.open()
        await switching.value
        #expect(model.projectTree?.projects.map(\.name) == ["p2-project"])
        #expect(model.recentSessions.map(\.storedID) == ["s-p2"])
        #expect(!model.browseLoading)
    }

    /// The same race on a backend without `projects.*`, where the refresh
    /// degrades to grouping the flat session list: P1's late flat list must
    /// not become P2's sidebar.
    @Test func aDegradedRefreshForTheOldProfileCannotPaintTheNewOne() async throws {
        let p1Hold = RequestHold()
        let armed = Flag()
        let server = try await HermesTestServer.start(
            rpcError: { method, _ in method == "projects.tree" ? (-32601, "no projects") : nil }
        ) { request in
            switch request.path {
            case "/api/status": return TestHTTPResponse(200, #"{"auth_required": false}"#)
            case "/api/profiles": return TestHTTPResponse(200, Self.twoProfiles)
            case "/api/profiles/sessions":
                if armed.isSet, request.query.contains("profile=p1") { p1Hold.wait() }
                return TestHTTPResponse(200, Self.recents(query: request.query))
            default: return TestHTTPResponse(200)
            }
        }
        defer { server.stop() }

        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let endpoint = try endpoint(server)
        let restore = isolate([endpoint], store: store)
        defer {
            p1Hold.release()
            restore()
        }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        try await connectAndWaitReady(model, endpoint)
        try #require(
            await eventually {
                model.selectedProfile == "p1" && !model.browseLoading && !model.recentSessions.isEmpty
            })

        armed.signal()
        let staleRefresh = Task { await model.refreshProjects() }
        #expect(await p1Hold.reached.wait(), "the P1 refresh never asked for its flat list")
        await model.selectProfile("p2")
        #expect(model.recentSessions.map(\.storedID) == ["s-p2"])

        p1Hold.release()
        await staleRefresh.value
        #expect(model.recentSessions.map(\.storedID) == ["s-p2"], "P1's flat list painted P2's sidebar")
    }

    /// The first refresh goes out before the profile list arrives (no
    /// profile: every profile's sessions). Selecting the default profile
    /// when the list lands must re-fetch for it, so the picker, tree, and
    /// recents agree.
    @Test func theInitialDefaultProfileSelectionRefreshesForIt() async throws {
        let script = Script()
        let profilesHold = RequestHold()
        let server = try await HermesTestServer.start(
            rpc: { method, params in
                method == "projects.tree"
                    ? Self.tree(for: params["profile"]?.stringValue ?? "all") : nil
            }
        ) { request in
            switch request.path {
            case "/api/status": return TestHTTPResponse(200, #"{"auth_required": false}"#)
            case "/api/profiles":
                profilesHold.wait()
                return TestHTTPResponse(200, Self.twoProfiles)
            case "/api/profiles/sessions":
                script.record(request.query)
                return TestHTTPResponse(200, Self.recents(query: request.query))
            default: return TestHTTPResponse(200)
            }
        }
        defer { server.stop() }

        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let endpoint = try endpoint(server)
        let restore = isolate([endpoint], store: store)
        defer {
            profilesHold.release()
            restore()
        }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        try await connectAndWaitReady(model, endpoint)
        #expect(await profilesHold.reached.wait(), "the profile list was never requested")
        // The unscoped first load lands while the list is still out.
        #expect(await eventually { model.recentSessions.map(\.storedID) == ["s-all"] })

        profilesHold.release()
        #expect(await eventually { model.selectedProfile == "p1" })
        let agrees = await eventually {
            model.projectTree?.projects.map(\.name) == ["p1-project"]
                && model.recentSessions.map(\.storedID) == ["s-p1"]
                && !model.browseLoading
        }
        #expect(
            agrees,
            "picker says p1 but the sidebar shows \(model.projectTree?.projects.map(\.name) ?? []) / \(model.recentSessions.map(\.storedID))")
        #expect(script.recentsQueries.contains { $0.contains("profile=p1") })
        let treeProfiles = server.rpcRequests.filter { $0.method == "projects.tree" }
            .map { $0.params["profile"]?.stringValue }
        #expect(treeProfiles.contains("p1"))
    }
}
