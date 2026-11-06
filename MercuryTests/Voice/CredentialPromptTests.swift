import Foundation
import MercuryKit
import Testing

/// Sudo and secret server requests are collected on screen and answered
/// through `request.answer`; the value is never spoken or logged.
@MainActor
@Suite("Credential prompts", .timeLimit(.minutes(1)))
struct CredentialPromptTests {

    static let runtimeID = "rt1"
    static let storedID = "st1"
    static let watermark = 10
    static let sudoNotice = "Hermes needs your sudo password. It's on screen."
    static let secretNotice = "Hermes needs a secret. It's on screen."

    private func openedController(
        service: ScriptedSessionService,
        speech: RecordingSpeech = RecordingSpeech(),
        openRequests: [JSONValue]? = nil
    ) async throws -> ConversationController {
        service.enqueueResume(
            Fixtures.resumeResult(
                runtimeID: Self.runtimeID, storedID: Self.storedID, openRequests: openRequests))
        let controller = makeController(service: service, speech: speech)
        try await controller.openSession(mode: .resume(storedID: Self.storedID))
        controller.handle(
            event: Fixtures.event(
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: Self.watermark)))
        return controller
    }

    private func reconnect(
        _ controller: ConversationController,
        service: ScriptedSessionService,
        openRequests: [JSONValue]?
    ) async {
        service.enqueueResume(
            Fixtures.resumeResult(runtimeID: Self.runtimeID, storedID: Self.storedID))
        service.enqueueBatch(Fixtures.replayBatch([], latestSeq: Self.watermark))
        service.enqueueActivation(
            Fixtures.activateResult(
                runtimeID: Self.runtimeID, sessionKey: Self.storedID,
                openRequests: openRequests))
        await controller.connectionBecameReady(isReconnect: true)
    }

    private func sudo(id: String = "srq-s1") -> JSONValue {
        srq(id: id, method: "sudo", params: ["command": "apt install jq"])
    }

    private func secret(id: String = "srq-k1") -> JSONValue {
        srq(
            id: id, method: "secret",
            params: ["env_var": "API_KEY", "prompt": "Paste the key for the weather skill"])
    }

    private func srq(id: String, method: String, params: [String: JSONValue]) -> JSONValue {
        var params = params
        params["session_id"] = .string(Self.runtimeID)
        return .object(["id": .string(id), "method": .string(method), "params": .object(params)])
    }

    private func cancel(_ id: String, seq: Int) -> GatewayEvent {
        Fixtures.event(
            Fixtures.requestCancel(sessionID: Self.runtimeID, seq: seq, id: id, method: "sudo"))
    }

    // MARK: Presenting

    @Test func sudoServerRequestPausesListeningAndAnnouncesFixedText() async throws {
        let service = ScriptedSessionService()
        let speech = RecordingSpeech()
        let controller = try await openedController(service: service, speech: speech)

        controller.handle(event: Fixtures.serverRequestEvent(sudo()))
        controller.handle(event: Fixtures.serverRequestEvent(sudo()))  // same id: not queued twice
        await controller.awaitPromptAnnouncements()

        guard case .sudo(let shown)? = controller.currentCredentialPrompt else {
            Issue.record("expected a sudo prompt")
            return
        }
        #expect(shown.requestID == "srq-s1")
        #expect(controller.credentialPrompts.count == 1)
        #expect(controller.approval == nil && controller.clarify == nil)
        #expect(speech.spoken == [Self.sudoNotice])
        #expect(!speech.spoken.joined().contains("apt install jq"))
        #expect(service.promptResponses.isEmpty)
        await controller.teardown()
    }

    @Test func secretServerRequestIsQueuedBehindSudo() async throws {
        let service = ScriptedSessionService()
        let speech = RecordingSpeech()
        let controller = try await openedController(service: service, speech: speech)

        controller.handle(event: Fixtures.serverRequestEvent(sudo()))
        controller.handle(event: Fixtures.serverRequestEvent(secret()))
        await controller.awaitPromptAnnouncements()

        #expect(controller.credentialPrompts.map(\.id) == ["srq-s1", "srq-k1"])
        #expect(controller.currentCredentialPrompt?.id == "srq-s1")
        #expect(speech.spoken == [Self.sudoNotice])  // the secret waits its turn

        // Withdrawing the front one brings the secret up, announced with
        // fixed text that omits the request's own prompt.
        controller.handle(event: cancel("srq-s1", seq: 11))
        await controller.awaitPromptAnnouncements()
        #expect(controller.currentCredentialPrompt?.id == "srq-k1")
        #expect(speech.spoken == [Self.sudoNotice, Self.secretNotice])
        await controller.teardown()
    }

    @Test func otherServerRequestMethodsAreIgnored() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(
            event: Fixtures.serverRequestEvent(
                srq(id: "srq-v1", method: "vault.read", params: ["site": "GitHub"])))
        controller.handle(
            event: Fixtures.serverRequestEvent(
                srq(id: "srq-t1", method: "tour", params: ["action": "start"])))
        #expect(controller.currentCredentialPrompt == nil)
        await controller.teardown()
    }

    // MARK: Answering

    @Test func answerSendsValueViaRequestAnswerAndResumes() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        var settled: [String] = []
        controller.serverRequestSettled = { id, runtime in settled.append("\(id)@\(runtime)") }
        controller.handle(event: Fixtures.serverRequestEvent(sudo()))

        let gate = CallGate()
        service.promptResponseGate = gate
        async let outcome = controller.answerCredential("pw")
        await gate.waitUntilEntered()
        #expect(controller.currentCredentialPrompt != nil)  // kept until the reply lands
        #expect(controller.promptResponseInFlight)
        await gate.release()

        #expect(await outcome == .done)
        #expect(
            service.promptResponses == [
                .requestAnswer(
                    params: .object([
                        "id": "srq-s1", "result": ServerRequestResult.value("pw"),
                    ]))
            ])
        #expect(controller.currentCredentialPrompt == nil)
        #expect(!controller.promptResponseInFlight)
        #expect(controller.promptSendError == nil)
        #expect(settled == ["srq-s1@rt1"])
        await controller.teardown()
    }

    @Test func declineSendsEmptyValueAndResumes() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        var settled: [String] = []
        controller.serverRequestSettled = { id, _ in settled.append(id) }
        controller.handle(event: Fixtures.serverRequestEvent(secret()))

        #expect(await controller.declineCredential() == .done)
        #expect(
            service.promptResponses == [
                .requestAnswer(
                    params: .object(["id": "srq-k1", "result": ServerRequestResult.value("")]))
            ])
        #expect(controller.currentCredentialPrompt == nil)
        #expect(settled == ["srq-k1"])
        await controller.teardown()
    }

    @Test func expiredAnswerStillClosesThePrompt() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(event: Fixtures.serverRequestEvent(sudo()))
        service.enqueueAnswerReply(.expired)

        #expect(await controller.answerCredential("pw") == .done)
        #expect(controller.currentCredentialPrompt == nil)
        await controller.teardown()
    }

    @Test func failedAnswerKeepsThePromptAndReportsTheError() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        var settled: [String] = []
        controller.serverRequestSettled = { id, _ in settled.append(id) }
        controller.handle(event: Fixtures.serverRequestEvent(sudo()))
        service.enqueueAnswerFailure()

        let outcome = await controller.answerCredential("pw")
        guard case .failed(let message) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(!message.isEmpty)
        #expect(!message.contains("pw"))
        #expect(controller.currentCredentialPrompt?.id == "srq-s1")
        #expect(settled.isEmpty)

        // The retry delivers.
        #expect(await controller.answerCredential("pw") == .done)
        #expect(controller.currentCredentialPrompt == nil)
        await controller.teardown()
    }

    @Test func answeringTheFrontPromptAdvancesToTheNext() async throws {
        let service = ScriptedSessionService()
        let speech = RecordingSpeech()
        let controller = try await openedController(service: service, speech: speech)
        controller.handle(event: Fixtures.serverRequestEvent(sudo()))
        controller.handle(event: Fixtures.serverRequestEvent(secret()))

        #expect(await controller.answerCredential("pw") == .done)
        #expect(controller.currentCredentialPrompt?.id == "srq-k1")
        await controller.awaitPromptAnnouncements()
        #expect(speech.spoken.last == Self.secretNotice)
        await controller.teardown()
    }

    // MARK: Withdrawal

    @Test func requestCancelWithdrawsThePrompt() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(event: Fixtures.serverRequestEvent(sudo()))

        controller.handle(event: cancel("srq-other", seq: 11))
        #expect(controller.credentialPrompts.count == 1)
        controller.handle(event: cancel("srq-s1", seq: 12))
        #expect(controller.currentCredentialPrompt == nil)
        await controller.teardown()
    }

    @Test func aTextChatAnsweringWithdrawsThePrompt() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(event: Fixtures.serverRequestEvent(sudo()))
        controller.handle(event: Fixtures.serverRequestEvent(secret()))

        controller.withdrawSettledRequest("srq-s1")
        #expect(controller.credentialPrompts.map(\.id) == ["srq-k1"])
        controller.withdrawSettledRequest("srq-k1")
        #expect(controller.currentCredentialPrompt == nil)
        #expect(service.promptResponses.isEmpty)
        await controller.teardown()
    }

    // MARK: Reconnect

    @Test func reconnectRestoresOpenCredentialRequests() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        await reconnect(controller, service: service, openRequests: [sudo()])
        #expect(controller.currentCredentialPrompt?.id == "srq-s1")
        #expect(controller.credentialPrompts.count == 1)

        await reconnect(controller, service: service, openRequests: [sudo()])
        #expect(controller.credentialPrompts.count == 1)  // presented once

        await reconnect(controller, service: service, openRequests: [])
        #expect(controller.currentCredentialPrompt == nil)
        await controller.teardown()
    }

    @Test func aCredentialRequestOpenAtResumeIsPresented() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service, openRequests: [secret()])
        #expect(controller.currentCredentialPrompt?.id == "srq-k1")
        await controller.teardown()
    }
}
