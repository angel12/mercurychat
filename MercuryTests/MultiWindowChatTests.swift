import Foundation
import MercuryKit
import Testing

/// Issue #112: every window's ChatView registered its controller in ONE
/// app-wide `activeChat` slot, and gateway events reached only that slot —
/// opening a chat in a second window silently stopped the first window's
/// updates, and closing either cleared the slot for both. Navigation was one
/// app-wide route too. Now each window owns its route, every open chat
/// receives the event stream, and a runtime two windows share (the backend
/// resumes a live stored session onto the SAME runtime) is closed only by
/// the last chat to leave it.
@Suite("Multiple windows", .timeLimit(.minutes(1)))
@MainActor
struct MultiWindowChatTests {
    /// Scripted gateway: `stored-X` resumes onto runtime `rt-X` — every time,
    /// like the backend's live-session fast path. Lock-guarded.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var resumes: [String: Int] = [:]
        private var holdNextResumeOf: (String, TestReplyGate)?

        /// Hold the next `session.resume` of `storedID` until `gate` opens.
        func holdNextResume(of storedID: String, _ gate: TestReplyGate) {
            lock.withLock { holdNextResumeOf = (storedID, gate) }
        }

        func resumeCount(_ storedID: String) -> Int {
            lock.withLock { resumes[storedID] ?? 0 }
        }

        func respond(method: String, params: JSONValue) -> JSONValue? {
            switch method {
            case "session.resume":
                let stored = params["session_id"]?.stringValue ?? ""
                lock.withLock { resumes[stored, default: 0] += 1 }
                let runtime = "rt-" + stored.replacingOccurrences(of: "stored-", with: "")
                return .object([
                    "session_id": .string(runtime), "stored_session_id": .string(stored),
                ])
            case "session.create":
                if params["title"]?.stringValue == MultiWindowChatTests.createTitle {
                    return .object([
                        "session_id": "rt-new", "stored_session_id": "stored-new",
                    ])
                }
                return .object(["session_id": "rt-probe"])  // the contract probe
            case "session.close":
                return .object(["closed": true])
            case "request.answer":
                return .object(["status": "ok"])
            default:
                return .object([:])
            }
        }

        func hold(method: String, params: JSONValue) -> TestReplyGate? {
            guard method == "session.resume" else { return nil }
            return lock.withLock {
                guard let (stored, gate) = holdNextResumeOf,
                    params["session_id"]?.stringValue == stored
                else { return nil }
                holdNextResumeOf = nil
                return gate
            }
        }
    }

    nonisolated static let createTitle = "Multi-window create"

    private func connectedModel(
        _ script: Script,
        createGate: TestReplyGate? = nil
    ) async throws -> (AppModel, HermesTestServer, () -> Void) {
        let server = try await HermesTestServer.start(
            rpc: { method, params in script.respond(method: method, params: params) },
            rpcHold: { method, params in
                if method == "session.create",
                    params["title"]?.stringValue == Self.createTitle
                {
                    return createGate
                }
                return script.hold(method: method, params: params)
            }
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
        return (
            model, server,
            {
                model.disconnect()
                server.stop()
                try? store.deleteToken(for: endpoint)
            }
        )
    }

    private func session(_ storedID: String) throws -> SessionSummary {
        try #require(SessionSummary(json: .object(["session_id": .string(storedID)])))
    }

    /// Open a chat and resume `storedID` onto its runtime, as ChatView does.
    private func resumedChat(_ model: AppModel, _ storedID: String) async throws -> ChatController {
        let chat = try #require(model.openChat(profile: nil))
        await chat.begin(.resume(try session(storedID)))
        try #require(chat.runtimeID != nil)
        return chat
    }

    private func closes(_ server: HermesTestServer, _ runtimeID: String) -> Int {
        server.rpcRequests.filter {
            $0.method == "session.close" && $0.params["session_id"]?.stringValue == runtimeID
        }.count
    }

    private func pushTitle(_ server: HermesTestServer, _ runtimeID: String, _ title: String) {
        server.pushEvent("session.title", sessionID: runtimeID, payload: ["title": .string(title)])
    }

    // MARK: Event routing

    /// The original bug: the second window's open took the first's events.
    @Test func openingASecondChatKeepsTheFirstReceiving() async throws {
        let (model, server, cleanup) = try await connectedModel(Script())
        defer { cleanup() }

        let first = try await resumedChat(model, "stored-a")
        _ = try await resumedChat(model, "stored-b")

        pushTitle(server, "rt-a", "A1")
        #expect(await eventually { first.store.title == "A1" }, "the first window went deaf")
    }

    @Test func twoChatsEachReceiveTheirOwnEventsAndSurviveTheOthersClose() async throws {
        let (model, server, cleanup) = try await connectedModel(Script())
        defer { cleanup() }

        let a = try await resumedChat(model, "stored-a")
        let b = try await resumedChat(model, "stored-b")

        pushTitle(server, "rt-a", "A1")
        pushTitle(server, "rt-b", "B1")
        #expect(await eventually { a.store.title == "A1" && b.store.title == "B1" })

        // Closing one window's chat must not unregister (or close) the other.
        model.closeChat(a)
        #expect(await eventually(within: 3) { closes(server, "rt-a") == 1 })
        pushTitle(server, "rt-b", "B2")
        #expect(await eventually { b.store.title == "B2" }, "closing A cleared B's recipient")
        #expect(closes(server, "rt-b") == 0)
        #expect(model.openChats.count == 1 && model.openChats.first === b)
    }

    /// A closed chat is out of the fan-out: nothing more reaches it.
    @Test func aClosedChatStopsReceiving() async throws {
        let (model, server, cleanup) = try await connectedModel(Script())
        defer { cleanup() }

        let a = try await resumedChat(model, "stored-a")
        let b = try await resumedChat(model, "stored-b")
        model.closeChat(a)
        pushTitle(server, "rt-a", "late")
        pushTitle(server, "rt-b", "B1")
        #expect(await eventually { b.store.title == "B1" })
        #expect(a.store.title == nil)
    }

    // MARK: Shared runtimes

    @Test func aSharedRuntimeIsClosedOnlyByTheLastChat() async throws {
        let (model, server, cleanup) = try await connectedModel(Script())
        defer { cleanup() }

        let a = try await resumedChat(model, "stored-a")
        let b = try await resumedChat(model, "stored-a")
        #expect(a.runtimeID == "rt-a" && b.runtimeID == "rt-a")

        // Both windows show the session's live events.
        pushTitle(server, "rt-a", "shared")
        #expect(await eventually { a.store.title == "shared" && b.store.title == "shared" })

        model.closeChat(a)
        // Give a stray close time to land: B still shows this runtime.
        try await Task.sleep(for: .milliseconds(500))
        #expect(closes(server, "rt-a") == 0, "closing A killed B's runtime")
        pushTitle(server, "rt-a", "still live")
        #expect(await eventually { b.store.title == "still live" })

        model.closeChat(b)
        #expect(await eventually(within: 3) { closes(server, "rt-a") == 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(closes(server, "rt-a") == 1)
    }

    /// Window B is still resuming the session A shows when A closes: B has no
    /// runtime yet, but the backend will hand it A's live one — so A must not
    /// close it out from under B.
    @Test func aResumeInFlightKeepsTheRuntimeOpen() async throws {
        let script = Script()
        let (model, server, cleanup) = try await connectedModel(script)
        let gate = TestReplyGate()
        defer {
            gate.open()
            cleanup()
        }

        let a = try await resumedChat(model, "stored-a")
        script.holdNextResume(of: "stored-a", gate)
        let b = try #require(model.openChat(profile: nil))
        let resuming = Task { await b.begin(.resume(try session("stored-a"))) }
        #expect(await gate.reached.wait(), "B's resume never arrived")

        model.closeChat(a)
        try await Task.sleep(for: .milliseconds(300))
        #expect(closes(server, "rt-a") == 0, "A closed the runtime B is resuming onto")
        gate.open()
        _ = await resuming.result
        #expect(b.runtimeID == "rt-a")
        try await Task.sleep(for: .milliseconds(200))
        #expect(closes(server, "rt-a") == 0)
    }

    /// #111's relinquish of an abandoned create is guarded the same way: a
    /// chat that picked the new session up keeps its runtime.
    @Test func anAbandonedCreateSparesARuntimeAnotherChatHolds() async throws {
        let script = Script()
        let gate = TestReplyGate()
        let (model, server, cleanup) = try await connectedModel(script, createGate: gate)
        defer {
            gate.open()
            cleanup()
        }

        let creator = try #require(model.openChat(profile: nil))
        let creating = Task { await creator.begin(.create(cwd: nil, title: Self.createTitle)) }
        #expect(await gate.reached.wait(), "the create never arrived")
        // Another window resumes the new session onto its runtime meanwhile.
        let other = try await resumedChat(model, "stored-new")
        #expect(other.runtimeID == "rt-new")

        model.closeChat(creator)
        gate.open()
        await creating.value
        try await Task.sleep(for: .milliseconds(500))
        #expect(closes(server, "rt-new") == 0, "the abandoned create closed another chat's runtime")
    }

    /// One socket delivers a server request once and answering it emits
    /// nothing, so the answering chat tells its runtime's other chats.
    @Test func anAnsweredPromptClearsInEveryWindowOnTheRuntime() async throws {
        let (model, server, cleanup) = try await connectedModel(Script())
        defer { cleanup() }

        let a = try await resumedChat(model, "stored-a")
        let b = try await resumedChat(model, "stored-a")
        let elsewhere = try await resumedChat(model, "stored-b")
        server.push([
            "jsonrpc": "2.0", "id": "srq-aaaaaaaaaaa1", "method": "approval",
            "params": ["session_id": "rt-a", "request_id": "ap1", "command": "rm -rf build"],
        ])
        server.push([
            "jsonrpc": "2.0", "id": "srq-bbbbbbbbbbb1", "method": "approval",
            "params": ["session_id": "rt-b", "request_id": "ap2", "command": "ls"],
        ])
        #expect(
            await eventually {
                a.store.pendingApproval != nil && b.store.pendingApproval != nil
                    && elsewhere.store.pendingApproval != nil
            })

        let approval = try #require(a.store.pendingApproval)
        #expect(await a.respondApproval(approval, choice: "once"))
        #expect(await eventually { b.store.pendingApproval == nil }, "B kept the answered card")
        // Another runtime's request is untouched.
        #expect(elsewhere.store.pendingApproval?.serverRequestID == "srq-bbbbbbbbbbb1")
    }

    // MARK: Reconnect and disconnect

    @Test func aReconnectReachesEveryOpenChat() async throws {
        let script = Script()
        let (model, server, cleanup) = try await connectedModel(script)
        defer { cleanup() }

        _ = try await resumedChat(model, "stored-a")
        _ = try await resumedChat(model, "stored-b")
        #expect(script.resumeCount("stored-a") == 1 && script.resumeCount("stored-b") == 1)

        server.dropSockets()
        // No seq watermark, so each chat takes the full re-resume path.
        #expect(
            await eventually(within: 10) {
                script.resumeCount("stored-a") >= 2 && script.resumeCount("stored-b") >= 2
            }, "a window's chat never re-bound after the reconnect")
    }

    @Test func disconnectInvalidatesEveryChatAndClearsEveryWindow() async throws {
        let (model, _, cleanup) = try await connectedModel(Script())
        defer { cleanup() }

        let one = WindowNavigation(route: .session(try session("stored-a")))
        let two = WindowNavigation(route: .newSession(cwd: nil, request: UUID()))
        model.register(one)
        model.register(two)
        let a = try await resumedChat(model, "stored-a")
        let b = try await resumedChat(model, "stored-b")

        model.disconnect()
        #expect(a.isInvalidated && b.isInvalidated)
        #expect(model.openChats.isEmpty)
        #expect(one.route == nil && two.route == nil)
    }

    // MARK: Per-window navigation

    @Test func deletingASessionClearsOnlyTheWindowsShowingIt() async throws {
        let (model, _, cleanup) = try await connectedModel(Script())
        defer { cleanup() }

        let deleted = try session("stored-a")
        let showingIt = WindowNavigation(route: .session(deleted))
        let alsoShowingIt = WindowNavigation(route: .session(deleted))
        let showingAnother = WindowNavigation(route: .session(try session("stored-b")))
        let creating = WindowNavigation(route: .newSession(cwd: nil, request: UUID()))
        for window in [showingIt, alsoShowingIt, showingAnother, creating] {
            model.register(window)
        }

        await model.deleteSession(deleted)
        #expect(model.browseError == nil)
        #expect(showingIt.route == nil && alsoShowingIt.route == nil)
        #expect(showingAnother.route == .session(try session("stored-b")))
        guard case .newSession = creating.route else {
            Issue.record("the new-session window lost its route: \(String(describing: creating.route))")
            return
        }
    }

    @Test func newSessionInOneWindowLeavesTheOthersAlone() async throws {
        let (model, _, cleanup) = try await connectedModel(Script())
        defer { cleanup() }
        try #require(await eventually { model.isConnected })

        let shown = try session("stored-a")
        let other = WindowNavigation(route: .session(shown))
        let focused = WindowNavigation()
        model.register(other)
        model.register(focused)

        model.requestNewSession(cwd: "/work/repo", in: focused)
        #expect(other.route == .session(shown))
        guard case .newSession(let cwd, _) = focused.route else {
            Issue.record("expected a new-session route, got \(String(describing: focused.route))")
            return
        }
        #expect(cwd == "/work/repo")
    }
}
