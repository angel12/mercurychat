import ChatCore
import Foundation
import MercuryKit
import Testing

/// Composer slash commands, `/btw`, and prompts forwarded to the gateway
/// that owns the chat (hermes v0.23, desktop contract 8). Slash text must
/// never reach `prompt.submit` as a message, a skill's expanded body must
/// never show in the bubble, and an unconfirmed forward must not offer a
/// retry that could run the prompt twice.
@Suite("Slash commands and shared-chat sends", .timeLimit(.minutes(1)))
@MainActor
struct SlashCommandControllerTests {
    /// Replies keyed by method; anything else answers `{}`.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String: TestRPCReply] = [:]

        func set(_ method: String, _ reply: TestRPCReply) {
            lock.withLock { replies[method] = reply }
        }

        func reply(_ method: String) -> TestRPCReply? {
            if method == "session.create" { return .result(["session_id": "rt-1"]) }
            return lock.withLock { replies[method] }
        }
    }

    private func openChat(_ script: Script) async throws
        -> (ChatController, HermesTestServer, () -> Void)
    {
        let server = try await HermesTestServer.start(
            rpcReply: { method, _ in script.reply(method) }
        ) { request in
            request.path == "/api/status"
                ? TestHTTPResponse(200, #"{"auth_required": false}"#)
                : TestHTTPResponse(200, #"{"messages": []}"#)
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
        let chat = try #require(model.openChat(profile: nil))
        await chat.begin(.create(cwd: nil, title: nil))
        try #require(chat.runtimeID == "rt-1")
        return (
            chat, server,
            {
                model.disconnect()
                server.stop()
                try? store.deleteToken(for: endpoint)
            }
        )
    }

    private func requests(_ server: HermesTestServer, _ method: String) -> [TestRPCRequest] {
        server.rpcRequests.filter { $0.method == method }
    }

    private func notices(_ chat: ChatController) -> [SystemNotice] {
        chat.store.items.compactMap { item in
            if case .notice(let notice) = item { return notice }
            return nil
        }
    }

    private func users(_ chat: ChatController) -> [UserMessage] {
        chat.store.items.compactMap { item in
            if case .user(let message) = item { return message }
            return nil
        }
    }

    @Test func commandOutputIsShownAndNothingIsSubmitted() async throws {
        let script = Script()
        script.set("slash.exec", .result(["output": "Current model: gpt-x"]))
        let (chat, server, cleanup) = try await openChat(script)
        defer { cleanup() }

        await chat.submit("/model gpt-x")

        #expect(requests(server, "slash.exec").last?.params["command"] == "model gpt-x")
        #expect(requests(server, "prompt.submit").isEmpty)
        #expect(users(chat).isEmpty)
        #expect(notices(chat).last == SystemNotice(
            id: notices(chat).last?.id ?? "", text: "/model gpt-x\nCurrent model: gpt-x", level: .output))
    }

    @Test func skillSendsItsBodyButShowsTheInvocation() async throws {
        let script = Script()
        script.set(
            "slash.exec",
            .result(["type": "skill", "name": "work", "message": "EXPANDED BODY", "display": "/work fix it"]))
        script.set("prompt.submit", .result(["status": "streaming"]))
        let (chat, server, cleanup) = try await openChat(script)
        defer { cleanup() }

        await chat.submit("/work fix it")

        #expect(requests(server, "prompt.submit").last?.params["text"] == "EXPANDED BODY")
        #expect(users(chat).map(\.text) == ["/work fix it"])
        #expect(users(chat).first?.sendState == .sent)
    }

    @Test func retryingAFailedSkillResendsTheBody() async throws {
        let script = Script()
        script.set(
            "slash.exec", .result(["type": "skill", "name": "work", "message": "BODY", "display": "/work"]))
        script.set("prompt.submit", .error(code: 5000, message: "boom"))
        let (chat, server, cleanup) = try await openChat(script)
        defer { cleanup() }

        await chat.submit("/work")
        let echo = try #require(users(chat).first)
        #expect(echo.sendState == .failed)

        script.set("prompt.submit", .result(["status": "streaming"]))
        await chat.retrySend(messageID: echo.id)

        #expect(requests(server, "prompt.submit").map { $0.params["text"] } == ["BODY", "BODY"])
        #expect(users(chat).first?.sendState == .sent)
    }

    @Test func prefillGoesToTheComposer() async throws {
        let script = Script()
        script.set("slash.exec", .result(["type": "prefill", "message": "my last message"]))
        let (chat, _, cleanup) = try await openChat(script)
        defer { cleanup() }

        await chat.submit("/undo")

        #expect(chat.composerPrefill == "my last message")
    }

    @Test func newChatAndBarePickersAreHandledLocally() async throws {
        let (chat, server, cleanup) = try await openChat(Script())
        defer { cleanup() }
        var newChats = 0
        chat.onNewChatRequested = { newChats += 1 }

        await chat.submit("/new")
        await chat.submit("/model")

        #expect(newChats == 1)
        #expect(chat.settingsRequested)
        #expect(requests(server, "slash.exec").isEmpty)
    }

    @Test func sideQuestionUsesPromptBtw() async throws {
        let script = Script()
        script.set("prompt.btw", .result(["task_id": "t1"]))
        let (chat, server, cleanup) = try await openChat(script)
        defer { cleanup() }

        await chat.submit("/btw what are you doing?")

        #expect(requests(server, "prompt.btw").last?.params["text"] == "what are you doing?")
        #expect(requests(server, "prompt.submit").isEmpty)
    }

    @Test func pathsAreOrdinaryMessages() async throws {
        let script = Script()
        script.set("prompt.submit", .result(["status": "streaming"]))
        let (chat, server, cleanup) = try await openChat(script)
        defer { cleanup() }

        await chat.submit("/usr/bin/env is missing")

        #expect(requests(server, "slash.exec").isEmpty)
        #expect(requests(server, "prompt.submit").last?.params["text"] == "/usr/bin/env is missing")
    }

    @Test func forwardedPromptIsQueuedAndExplained() async throws {
        let script = Script()
        script.set(
            "prompt.submit", .result(["status": "queued", "admission_id": "a1", "forwarded": true]))
        let (chat, _, cleanup) = try await openChat(script)
        defer { cleanup() }

        await chat.submit("hello")

        #expect(users(chat).first?.sendState == .queued)
        #expect(notices(chat).contains { $0.text.contains("queued behind it") })
    }

    @Test func unconfirmedForwardOffersNoRetry() async throws {
        let script = Script()
        script.set(
            "prompt.submit",
            .error(
                code: 4090, message: "check the chat before sending it again",
                data: ["reason": "SESSION_OWNER_UNCONFIRMED"]))
        let (chat, server, cleanup) = try await openChat(script)
        defer { cleanup() }

        await chat.submit("hello")
        let echo = try #require(users(chat).first)
        #expect(echo.sendState == .unconfirmed)
        #expect(chat.errorMessage?.contains("check the chat") == true)

        // retrySend only resends a `.failed` echo.
        await chat.retrySend(messageID: echo.id)
        #expect(requests(server, "prompt.submit").count == 1)
    }

    @Test func busyOwnerRefusalStaysRetryable() async throws {
        let script = Script()
        script.set(
            "prompt.submit",
            .error(code: 4090, message: "Send it again when the current turn ends.",
                   data: ["reason": "SESSION_OWNER_BUSY"]))
        let (chat, _, cleanup) = try await openChat(script)
        defer { cleanup() }

        await chat.submit("hello")

        #expect(users(chat).first?.sendState == .failed)
    }
}
