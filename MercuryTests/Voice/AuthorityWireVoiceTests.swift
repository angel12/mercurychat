import Foundation
import MercuryKit
import Testing

/// Voice on the v0.23 session-authority wire (spec "Revision: authority
/// wire"). A prompt sent while another turn runs is admitted `queued` (or
/// `forwarded` on the legacy wire): the controller waits for its turn rather
/// than failing. A retried submit carries the same `submissionID`, so the
/// owner admits it once. The owner's two refusals show the kit's copy;
/// `SESSION_OWNER_UNCONFIRMED` offers no retry (a second copy could run).
///
/// The text path drives the same tracker submit closure a spoken turn does.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AuthorityWireVoiceTests {
    private static let notLive = HermesError.rpcError(
        code: 4007, message: "session no longer live; retry resume", data: nil)

    private func refusal(_ reason: String) -> HermesError {
        .rpcError(
            code: HermesError.RPCCode.sessionSlotRefused, message: "owner says no",
            data: ["reason": .string(reason)])
    }

    private func makeWireController(
        _ service: ScriptedSessionService,
        submit: @escaping @Sendable (String, String, Bool, String) async throws -> PromptSubmission
    ) -> ConversationController {
        ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: RecordingSpeech(),
            submitPrompt: submit, retryDelay: { _ in })
    }

    private func openedController(
        receipt: PromptSubmission
    ) async throws -> ConversationController {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let controller = makeWireController(service) { _, _, _, _ in receipt }
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        return controller
    }

    private func messageStart(_ sessionID: String) -> GatewayEvent {
        GatewayEvent(
            type: GatewayEvent.Kind.messageStart, sessionID: sessionID, payload: .object([:]))
    }

    @Test func queuedReceiptShowsWaitingAndIsNotAFailure() async throws {
        let controller = try await openedController(
            receipt: PromptSubmission(status: "queued", admissionID: "a1"))
        #expect(!controller.isWaitingForTurn)
        controller.submitTextPrompt("behind the bot")
        await controller.textSubmissionTask?.value
        #expect(controller.isWaitingForTurn)
        #expect(controller.textSubmissionError == nil)
        #expect(controller.failedText == nil)
        #expect(await controller.diagnosticTrackerState().busy)
        await controller.teardown()
    }

    @Test func forwardedReceiptShowsWaiting() async throws {
        let controller = try await openedController(
            receipt: PromptSubmission(status: nil, forwarded: true))
        controller.submitTextPrompt("forwarded")
        await controller.textSubmissionTask?.value
        #expect(controller.isWaitingForTurn)
        #expect(controller.failedText == nil)
        await controller.teardown()
    }

    @Test func streamingReceiptDoesNotWait() async throws {
        let controller = try await openedController(
            receipt: PromptSubmission(status: "streaming"))
        controller.submitTextPrompt("runs now")
        await controller.textSubmissionTask?.value
        #expect(!controller.isWaitingForTurn)
        await controller.teardown()
    }

    @Test func waitingClearsOnMessageStart() async throws {
        let controller = try await openedController(
            receipt: PromptSubmission(status: "queued", admissionID: "a1"))
        controller.submitTextPrompt("queued")
        await controller.textSubmissionTask?.value
        #expect(controller.isWaitingForTurn)

        controller.handle(event: messageStart("someone-else"))
        #expect(controller.isWaitingForTurn)

        controller.handle(event: messageStart("runtime"))
        #expect(!controller.isWaitingForTurn)
        await controller.teardown()
    }

    @Test func waitingClearsOnTeardownAndConnectionLost() async throws {
        let lost = try await openedController(
            receipt: PromptSubmission(status: "queued", admissionID: "a1"))
        lost.submitTextPrompt("queued")
        await lost.textSubmissionTask?.value
        #expect(lost.isWaitingForTurn)
        lost.connectionLost()
        #expect(!lost.isWaitingForTurn)
        await lost.teardown()

        let ended = try await openedController(
            receipt: PromptSubmission(status: "queued", admissionID: "a2"))
        ended.submitTextPrompt("queued")
        await ended.textSubmissionTask?.value
        #expect(ended.isWaitingForTurn)
        ended.supersede()
        #expect(!ended.isWaitingForTurn)
        await ended.teardown()
        #expect(!ended.isWaitingForTurn)
    }

    @Test func waitingClearsWhenTheNextSubmitThrows() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let calls = SubmissionIDLog()
        let controller = makeWireController(service) { _, _, _, id in
            if await calls.record(id) == 0 {
                return PromptSubmission(status: "queued", admissionID: "a1")
            }
            throw HermesError.notConnected
        }
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.submitTextPrompt("queued")
        await controller.textSubmissionTask?.value
        #expect(controller.isWaitingForTurn)
        controller.submitTextPrompt("fails")
        await controller.textSubmissionTask?.value
        #expect(controller.failedText == "fails")
        #expect(!controller.isWaitingForTurn)
        await controller.teardown()
    }

    @Test func reattachResubmitReusesSubmissionID() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        service.enqueueResume(Fixtures.resumeResult(runtimeID: "runtime-2", storedID: "stored"))
        let calls = SubmissionIDLog()
        let notLive = Self.notLive
        let controller = makeWireController(service) { _, _, _, id in
            if await calls.record(id) == 0 { throw notLive }
            return PromptSubmission(status: "streaming")
        }
        try await controller.openSession(mode: .create(cwd: nil, title: nil))

        controller.submitTextPrompt("hello")
        await controller.textSubmissionTask?.value
        #expect(controller.failedText == nil)
        var ids = await calls.ids
        try #require(ids.count == 2)
        #expect(!ids[0].isEmpty)
        #expect(ids[0] == ids[1])

        controller.submitTextPrompt("again")
        await controller.textSubmissionTask?.value
        ids = await calls.ids
        try #require(ids.count == 3)
        #expect(!ids[2].isEmpty)
        #expect(ids[2] != ids[0])
        await controller.teardown()
    }

    @Test func textSubmitOwnerBusyShowsKitCopy() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let error = refusal(HermesError.RefusalReason.sessionOwnerBusy)
        let controller = makeWireController(service) { _, _, _, _ in throw error }
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.submitTextPrompt("busy")
        await controller.textSubmissionTask?.value
        #expect(controller.textSubmissionError == error.errorDescription)
        // Nothing was sent: retry stays offered.
        #expect(controller.failedText == "busy")
        #expect(!controller.isWaitingForTurn)
        await controller.teardown()
    }

    @Test func textSubmitOwnerUnconfirmedOffersNoRetry() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let error = refusal(HermesError.RefusalReason.sessionOwnerUnconfirmed)
        let controller = makeWireController(service) { _, _, _, _ in throw error }
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.submitTextPrompt("maybe queued")
        await controller.textSubmissionTask?.value
        #expect(controller.textSubmissionError == error.errorDescription)
        // It may already be queued with the owner: a retry could run it twice.
        #expect(controller.failedText == nil)
        await controller.teardown()
    }
}

/// Every `submissionID` the seam saw, in call order.
private actor SubmissionIDLog {
    private(set) var ids: [String] = []

    /// Returns this call's zero-based index.
    func record(_ id: String) -> Int {
        ids.append(id)
        return ids.count - 1
    }
}
