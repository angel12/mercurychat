import Foundation
import MercuryKit
import Testing

/// Voice on the v0.23 session-authority wire (spec "Revision: authority
/// wire"). A prompt sent while another turn runs is admitted `queued` (or
/// `forwarded` on the legacy wire): the controller waits for its turn rather
/// than failing. A retried submit carries the same `submissionID`, so the
/// owner admits it once. The owner's two refusals show app copy (never the
/// server's text); `SESSION_OWNER_UNCONFIRMED` offers no retry (a second copy
/// could run).
///
/// Turn attribution (fix round 1): while our prompt waits, the turn ahead of
/// it is someone else's and never reaches the tracker; our turn is the next
/// `message.start` after our row leaves the queue.
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
        fed: FedEvents? = nil,
        submit: @escaping @Sendable (String, String, Bool, String) async throws -> PromptSubmission
    ) -> ConversationController {
        var beforeTrackerEvent: (@Sendable (GatewayEvent) async -> Void)?
        if let fed {
            beforeTrackerEvent = { event in await fed.record(event) }
        }
        return ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: RecordingSpeech(),
            beforeTrackerEvent: beforeTrackerEvent,
            submitPrompt: submit, retryDelay: { _ in })
    }

    private func openedController(
        receipt: PromptSubmission, fed: FedEvents? = nil
    ) async throws -> ConversationController {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let controller = makeWireController(service, fed: fed) { _, _, _, _ in receipt }
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        return controller
    }

    // MARK: Events

    private func turnEvent(
        _ type: String, _ payload: [String: JSONValue] = [:], session: String = "runtime"
    ) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: session, payload: .object(payload))
    }

    private func start(_ payload: [String: JSONValue] = [:]) -> GatewayEvent {
        turnEvent(GatewayEvent.Kind.messageStart, payload)
    }

    private func delta(_ text: String) -> GatewayEvent {
        turnEvent(GatewayEvent.Kind.messageDelta, ["text": .string(text)])
    }

    private func complete(_ text: String = "", _ extra: [String: JSONValue] = [:]) -> GatewayEvent {
        var payload = extra
        payload["text"] = .string(text)
        return turnEvent(GatewayEvent.Kind.messageComplete, payload)
    }

    /// A queued row's settling complete (`cancelled` or `steered`).
    private func settled(_ admission: String, _ outcome: String) -> GatewayEvent {
        turnEvent(
            GatewayEvent.Kind.messageComplete,
            ["admission_id": .string(admission), "outcome": .string(outcome)])
    }

    private static func row(
        _ admission: String, _ sequence: Int, _ status: String, steering: Bool = false
    ) -> JSONValue {
        .object([
            "admission_id": .string(admission), "sequence": .number(Double(sequence)),
            "text": .string("prompt \(admission)"), "status": .string(status),
            "steering": .bool(steering),
        ])
    }

    private func queue(_ rows: JSONValue...) -> GatewayEvent {
        turnEvent(GatewayEvent.Kind.sessionInfo, ["pending": .array(rows)])
    }

    private func submitQueued(_ controller: ConversationController) async {
        controller.submitTextPrompt("mine")
        await controller.textSubmissionTask?.value
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

    @Test func waitingClearsOnTeardown() async throws {
        let ended = try await openedController(
            receipt: PromptSubmission(status: "queued", admissionID: "a2"))
        await submitQueued(ended)
        #expect(ended.isWaitingForTurn)
        ended.supersede()
        #expect(!ended.isWaitingForTurn)
        await ended.teardown()
        #expect(!ended.isWaitingForTurn)
    }

    // MARK: Turn attribution
    //
    // Fixtures follow the authority's real order (hermes v0.23): a claim
    // publishes the turn's `message.start` FIRST and then the `pending` list
    // showing the claimed row started or gone; a cancel/steer publishes the
    // `pending` list FIRST and then the row's settling `message.complete`.

    /// The brief's real-order case: our own start precedes the list that
    /// releases our row.
    @Test func ourTurnInRealWireOrderIsSpoken() async throws {
        let fed = FedEvents()
        let controller = try await openedController(
            receipt: PromptSubmission(status: "queued", admissionID: "a1"), fed: fed)
        await submitQueued(controller)
        controller.handle(event: queue(Self.row("a1", 1, "queued")))

        controller.handle(event: start())
        controller.handle(event: delta("theirs"))
        controller.handle(event: complete("theirs"))
        #expect(controller.isWaitingForTurn, "the turn ahead ended our wait")

        controller.handle(event: start())  // our claim…
        #expect(controller.isWaitingForTurn, "nothing says this start is ours yet")
        controller.handle(event: queue(Self.row("a1", 1, "started")))  // …then its list
        #expect(!controller.isWaitingForTurn)
        controller.handle(event: delta("ours"))
        controller.handle(event: complete("ours"))

        await controller.diagnosticFinishTrackerEvents()
        #expect(await fed.texts.allSatisfy { !$0.contains("theirs") })
        #expect(await fed.types == [
            GatewayEvent.Kind.messageStart, GatewayEvent.Kind.messageDelta,
            GatewayEvent.Kind.messageComplete,
        ])
        let state = await controller.diagnosticTrackerState()
        #expect(state.pendingText == "ours")
        #expect(!state.busy)
        await controller.teardown()
    }

    /// Each claim ahead of ours is a start followed by a list that still
    /// queues our row: those buffers are discarded; ours is flushed.
    @Test func aQueuedPromptDoesNotSpeakTheTurnAheadOfIt() async throws {
        let fed = FedEvents()
        let controller = try await openedController(
            receipt: PromptSubmission(status: "queued", admissionID: "a1"), fed: fed)
        await submitQueued(controller)
        controller.handle(event: queue(Self.row("b1", 1, "queued"), Self.row("a1", 2, "queued")))

        controller.handle(event: start())
        controller.handle(event: queue(Self.row("b1", 1, "started"), Self.row("a1", 2, "queued")))
        controller.handle(event: delta("theirs"))
        controller.handle(event: complete("theirs"))
        #expect(controller.isWaitingForTurn)

        controller.handle(event: start())
        controller.handle(event: delta("ours"))  // may land before the list
        controller.handle(event: queue(Self.row("a1", 2, "started")))
        #expect(!controller.isWaitingForTurn)
        controller.handle(event: complete("ours"))

        await controller.diagnosticFinishTrackerEvents()
        #expect(await fed.texts.allSatisfy { !$0.contains("theirs") })
        #expect(await fed.types == [
            GatewayEvent.Kind.messageStart, GatewayEvent.Kind.messageDelta,
            GatewayEvent.Kind.messageComplete,
        ])
        let state = await controller.diagnosticTrackerState()
        #expect(state.pendingText == "ours")
        #expect(!state.busy)
        await controller.teardown()
    }

    @Test func aForeignStartFollowedByAListStillQueuingUsIsDiscarded() async throws {
        let fed = FedEvents()
        let controller = try await openedController(
            receipt: PromptSubmission(status: "queued", admissionID: "a1"), fed: fed)
        await submitQueued(controller)
        controller.handle(event: queue(Self.row("a1", 1, "queued")))
        controller.handle(event: start())
        controller.handle(event: delta("theirs"))
        controller.handle(event: queue(Self.row("a1", 1, "queued")))
        controller.handle(event: delta(" more"))
        controller.handle(event: complete("theirs more"))
        #expect(controller.isWaitingForTurn)
        await controller.diagnosticFinishTrackerEvents()
        #expect(await fed.types.isEmpty)
        #expect(await controller.diagnosticTrackerState().busy)
        await controller.teardown()
    }

    /// The receipt can land after the `pending` list that already shows the
    /// row; the list is kept for it.
    @Test func aQueueListBeforeTheReceiptStillCounts() async throws {
        let fed = FedEvents()
        let controller = try await openedController(
            receipt: PromptSubmission(status: "queued", admissionID: "a1"), fed: fed)
        controller.handle(event: queue(Self.row("a1", 1, "queued")))
        await submitQueued(controller)
        #expect(controller.isWaitingForTurn)
        controller.handle(event: start())
        controller.handle(event: queue(Self.row("a1", 1, "started")))
        #expect(!controller.isWaitingForTurn)
        controller.handle(event: delta("ours"))
        await controller.diagnosticFinishTrackerEvents()
        #expect(await controller.diagnosticTrackerState().pendingText == "ours")
        await controller.teardown()
    }

    /// `unknown` (the owner restarted mid-turn) keeps the wait.
    @Test func anUnknownRowKeepsWaiting() async throws {
        let fed = FedEvents()
        let controller = try await openedController(
            receipt: PromptSubmission(status: "queued", admissionID: "a1"), fed: fed)
        await submitQueued(controller)
        controller.handle(event: queue(Self.row("a1", 1, "queued")))
        controller.handle(event: queue(Self.row("a1", 1, "unknown")))
        #expect(controller.isWaitingForTurn)
        controller.handle(event: start())
        controller.handle(event: queue(Self.row("a1", 1, "unknown")))
        controller.handle(event: delta("theirs"))
        #expect(controller.isWaitingForTurn)
        await controller.diagnosticFinishTrackerEvents()
        #expect(await fed.types.isEmpty)
        await controller.teardown()
    }

    @Test func aForeignCancelledCompleteDoesNotEndOurTurn() async throws {
        try await foreignSettleDoesNotEndOurTurn(outcome: "cancelled")
    }

    @Test func aForeignSteeredCompleteDoesNotEndOurTurn() async throws {
        try await foreignSettleDoesNotEndOurTurn(outcome: "steered")
    }

    private func foreignSettleDoesNotEndOurTurn(outcome: String) async throws {
        let fed = FedEvents()
        let controller = try await openedController(
            receipt: PromptSubmission(status: "streaming", admissionID: "a1"), fed: fed)
        await submitQueued(controller)
        controller.handle(event: start())
        controller.handle(event: delta("ours"))
        controller.handle(event: queue())
        controller.handle(event: settled("b9", outcome))
        controller.handle(event: delta(" still"))
        controller.handle(event: complete("ours still"))

        await controller.diagnosticFinishTrackerEvents()
        #expect(await fed.types == [
            GatewayEvent.Kind.messageStart, GatewayEvent.Kind.messageDelta,
            GatewayEvent.Kind.messageDelta, GatewayEvent.Kind.messageComplete,
        ])
        let state = await controller.diagnosticTrackerState()
        #expect(state.pendingText == "ours still", "the \(outcome) row sealed our bubble")
        #expect(!state.busy)
        await controller.teardown()
    }

    /// Our queued row was steered into the running turn (hermes v0.23): the
    /// list shows it `started` + `steering` at once; the `steered` settle
    /// comes only after the running turn's own complete. That turn's
    /// remaining output is ours, and a later claim is not.
    @Test func aSteeredQueuedRowJoinsTheRunningTurn() async throws {
        let fed = FedEvents()
        let controller = try await openedController(
            receipt: PromptSubmission(status: "queued", admissionID: "a1"), fed: fed)
        await submitQueued(controller)
        controller.handle(event: queue(Self.row("a1", 1, "queued")))
        controller.handle(event: delta("before the steer"))
        controller.handle(event: queue(Self.row("a1", 1, "started", steering: true)))
        #expect(!controller.isWaitingForTurn)
        controller.handle(event: delta("ours"))
        controller.handle(event: complete("ours"))
        controller.handle(event: queue())
        controller.handle(event: settled("a1", "steered"))
        #expect(!controller.isWaitingForTurn)

        // The next claim belongs to someone else.
        controller.handle(event: start())
        controller.handle(event: queue(Self.row("b2", 2, "started")))
        controller.handle(event: delta("theirs"))
        controller.handle(event: complete("theirs"))

        await controller.diagnosticFinishTrackerEvents()
        #expect(await fed.types == [
            GatewayEvent.Kind.messageDelta, GatewayEvent.Kind.messageComplete,
        ])
        let state = await controller.diagnosticTrackerState()
        #expect(state.pendingText == "ours")
        #expect(!state.busy)
        await controller.teardown()
    }

    /// An undelivered steer goes back to its queue place.
    @Test func aSteerThatGoesBackToTheQueueWaitsAgain() async throws {
        let controller = try await openedController(
            receipt: PromptSubmission(status: "queued", admissionID: "a1"))
        await submitQueued(controller)
        controller.handle(event: queue(Self.row("a1", 1, "started", steering: true)))
        #expect(!controller.isWaitingForTurn)
        controller.handle(event: queue(Self.row("a1", 1, "queued")))
        #expect(controller.isWaitingForTurn)
        await controller.teardown()
    }

    /// A claim's start followed by a list WITHOUT our row is not our claim
    /// (ours would be listed `started`): our row was cancelled or steered,
    /// and its own settle decides.
    @Test func aGoneRowDiscardsTheClaimBuffer() async throws {
        let fed = FedEvents()
        let controller = try await openedController(
            receipt: PromptSubmission(status: "queued", admissionID: "a1"), fed: fed)
        await submitQueued(controller)
        controller.handle(event: queue(Self.row("a1", 1, "queued")))
        controller.handle(event: start())
        controller.handle(event: delta("theirs"))
        controller.handle(event: queue())
        controller.handle(event: settled("a1", "cancelled"))

        #expect(!controller.isWaitingForTurn)
        #expect(controller.notice == "Your message was removed from the queue.")
        await controller.diagnosticFinishTrackerEvents()
        #expect(await fed.types.isEmpty)
        let state = await controller.diagnosticTrackerState()
        #expect(!state.busy)
        #expect(state.pendingText == nil)
        await controller.teardown()
    }

    /// The claim (start, then a list showing us `started`) landed before the
    /// receipt: our start already passed, so nothing more is waited for.
    @Test func aReceiptAfterAStartedListIsOpen() async throws {
        let fed = FedEvents()
        let controller = try await openedController(
            receipt: PromptSubmission(status: "queued", admissionID: "a1"), fed: fed)
        controller.handle(event: start())
        controller.handle(event: queue(Self.row("a1", 1, "started")))
        await submitQueued(controller)
        #expect(!controller.isWaitingForTurn)
        controller.handle(event: delta("ours"))
        controller.handle(event: complete("ours"))
        await controller.diagnosticFinishTrackerEvents()
        #expect(await controller.diagnosticTrackerState().pendingText == "ours")
        await controller.teardown()
    }

    /// The socket drops between our claim's start and its list: the buffer
    /// is kept, and the resume snapshot's `pending` decides it.
    @Test(arguments: [true, false])
    func reconnectMidClaimDecidesFromTheSnapshot(started: Bool) async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        service.enqueueResume(
            Fixtures.livePayload(
                runtimeID: "runtime", sessionKey: "stored", running: true,
                extra: [
                    "stored_session_id": .string("stored"),
                    "pending": .array([Self.row("a1", 1, started ? "started" : "queued")]),
                ]))
        service.enqueueBatchFailure()
        let fed = FedEvents()
        let controller = makeWireController(service, fed: fed) { _, _, _, _ in
            PromptSubmission(status: "queued", admissionID: "a1")
        }
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        await submitQueued(controller)
        controller.handle(event: queue(Self.row("a1", 1, "queued")))
        controller.handle(event: start())

        controller.connectionLost()
        await controller.connectionBecameReady(isReconnect: true)
        #expect(controller.isWaitingForTurn == !started)
        controller.handle(event: delta(started ? "ours" : "theirs"))
        await controller.diagnosticFinishTrackerEvents()
        if started {
            #expect(await fed.types == [
                GatewayEvent.Kind.messageStart, GatewayEvent.Kind.messageDelta,
            ])
            #expect(await controller.diagnosticTrackerState().pendingText == "ours")
        } else {
            #expect(await fed.types.isEmpty)
        }
        await controller.teardown()
    }

    @Test func ourQueuedPromptCancelledElsewhereGoesIdleWithANotice() async throws {
        let fed = FedEvents()
        let controller = try await openedController(
            receipt: PromptSubmission(status: "queued", admissionID: "a1"), fed: fed)
        await submitQueued(controller)
        controller.handle(event: queue(Self.row("a1", 1, "queued")))
        controller.handle(event: queue())
        controller.handle(event: settled("a1", "cancelled"))

        #expect(!controller.isWaitingForTurn)
        #expect(controller.notice == "Your message was removed from the queue.")
        await controller.diagnosticFinishTrackerEvents()
        #expect(await fed.types.isEmpty)
        let state = await controller.diagnosticTrackerState()
        #expect(!state.busy)
        #expect(state.pendingText == nil)
        await controller.teardown()
    }

    @Test func aRowAheadOfOursDoesNotClearTheWait() async throws {
        let fed = FedEvents()
        let controller = try await openedController(
            receipt: PromptSubmission(status: "queued", admissionID: "a1"), fed: fed)
        await submitQueued(controller)
        controller.handle(event: queue(Self.row("b1", 1, "queued"), Self.row("a1", 2, "queued")))
        controller.handle(event: start())
        controller.handle(event: queue(Self.row("b1", 1, "started"), Self.row("a1", 2, "queued")))
        controller.handle(event: delta("b1's reply"))
        #expect(controller.isWaitingForTurn)
        controller.handle(event: complete("b1's reply"))
        controller.handle(event: queue(Self.row("a1", 2, "queued")))
        #expect(controller.isWaitingForTurn)
        await controller.diagnosticFinishTrackerEvents()
        #expect(await fed.types.isEmpty)
        #expect(await controller.diagnosticTrackerState().busy)
        await controller.teardown()
    }

    /// The resume snapshot carries the authority's `pending` rows: a row
    /// still queued keeps the wait (and the tracker busy) across a reconnect.
    @Test func reconnectKeepsTheWait() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        service.enqueueResume(
            Fixtures.livePayload(
                runtimeID: "runtime", sessionKey: "stored", running: true,
                extra: [
                    "stored_session_id": .string("stored"),
                    "pending": .array([Self.row("a1", 1, "queued")]),
                ]))
        service.enqueueBatchFailure()
        let fed = FedEvents()
        let controller = makeWireController(service, fed: fed) { _, _, _, _ in
            PromptSubmission(status: "queued", admissionID: "a1")
        }
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        await submitQueued(controller)
        controller.handle(event: queue(Self.row("a1", 1, "queued")))

        controller.connectionLost()
        #expect(controller.isWaitingForTurn)
        await controller.connectionBecameReady(isReconnect: true)
        #expect(controller.isWaitingForTurn)

        // The turn ahead still finishes without reaching the tracker.
        controller.handle(event: delta("theirs"))
        controller.handle(event: complete("theirs"))
        controller.handle(event: start())
        controller.handle(event: queue(Self.row("a1", 1, "started")))
        #expect(!controller.isWaitingForTurn)
        controller.handle(event: delta("ours"))
        await controller.diagnosticFinishTrackerEvents()
        #expect(await fed.texts.allSatisfy { !$0.contains("theirs") })
        let state = await controller.diagnosticTrackerState()
        #expect(state.pendingText == "ours")
        #expect(state.busy)
        await controller.teardown()
    }

    /// Our row started while the socket was down: the snapshot no longer
    /// lists it, so the next start is ours.
    @Test func reconnectReleasesARowThatLeftTheQueue() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        service.enqueueResume(
            Fixtures.livePayload(
                runtimeID: "runtime", sessionKey: "stored", running: false,
                extra: ["stored_session_id": .string("stored"), "pending": .array([])]))
        service.enqueueBatchFailure()
        let controller = makeWireController(service) { _, _, _, _ in
            PromptSubmission(status: "queued", admissionID: "a1")
        }
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        await submitQueued(controller)
        controller.handle(event: queue(Self.row("a1", 1, "queued")))
        controller.connectionLost()
        await controller.connectionBecameReady(isReconnect: true)
        #expect(!controller.isWaitingForTurn)
        await controller.teardown()
    }

    /// Legacy wire: no admission ids. Everything before the next start
    /// belongs to the turn ahead; that start is ours.
    @Test func forwardedReceiptSkipsTheRunningTurn() async throws {
        let fed = FedEvents()
        let controller = try await openedController(
            receipt: PromptSubmission(status: nil, forwarded: true), fed: fed)
        controller.handle(event: start())  // the other app's turn, before ours
        await submitQueued(controller)
        #expect(controller.isWaitingForTurn)
        controller.handle(event: delta("theirs"))
        controller.handle(event: complete("theirs"))
        #expect(controller.isWaitingForTurn)
        controller.handle(event: start())
        #expect(!controller.isWaitingForTurn)
        controller.handle(event: delta("ours"))
        controller.handle(event: complete("ours"))

        await controller.diagnosticFinishTrackerEvents()
        #expect(await fed.texts.allSatisfy { !$0.contains("theirs") })
        #expect(await controller.diagnosticTrackerState().pendingText == "ours")
        await controller.teardown()
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

    @Test func textSubmitOwnerBusyShowsAppCopy() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let error = refusal(HermesError.RefusalReason.sessionOwnerBusy)
        let controller = makeWireController(service) { _, _, _, _ in throw error }
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.submitTextPrompt("busy")
        await controller.textSubmissionTask?.value
        #expect(
            controller.textSubmissionError
                == "Another app is running a turn in this chat and couldn't queue this. Send it again when that turn ends."
        )
        #expect(controller.textSubmissionError?.contains("owner says no") == false)
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
        #expect(
            controller.textSubmissionError
                == "Delivery is uncertain: the app running this chat didn't confirm it. Check the conversation before sending again."
        )
        #expect(controller.textSubmissionError?.contains("owner says no") == false)
        // It may already be queued with the owner: a retry could run it twice.
        #expect(controller.failedText == nil)
        await controller.teardown()
    }

    /// An explicit retry of the same failed text is the same send: it keeps
    /// the submission id, so an owner that did admit it admits it once.
    @Test func explicitRetryReusesTheSubmissionID() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let calls = SubmissionIDLog()
        let controller = makeWireController(service) { _, _, _, id in
            let index = await calls.record(id)
            if index == 0 || index == 2 { throw HermesError.connectionClosed("gone") }
            return PromptSubmission(status: "streaming")
        }
        try await controller.openSession(mode: .create(cwd: nil, title: nil))

        controller.submitTextPrompt("first")  // fails
        await controller.textSubmissionTask?.value
        controller.submitTextPrompt("first")  // explicit retry: succeeds
        await controller.textSubmissionTask?.value
        #expect(controller.failedText == nil)
        controller.submitTextPrompt("first")  // a new send of the same text: fails
        await controller.textSubmissionTask?.value
        controller.dismissFailedText()
        controller.submitTextPrompt("second")  // different text
        await controller.textSubmissionTask?.value

        let ids = await calls.ids
        try #require(ids.count == 4)
        #expect(ids[1] == ids[0], "the retry minted a new id")
        #expect(ids[2] != ids[1], "a successful send's id was reused")
        #expect(ids[3] != ids[2], "a different text reused the failed id")
        await controller.teardown()
    }
}

/// The turn events the tracker was fed, in order.
private actor FedEvents {
    private(set) var events: [GatewayEvent] = []
    func record(_ event: GatewayEvent) { events.append(event) }
    var types: [String] { events.map(\.type) }
    var texts: [String] { events.compactMap { $0.payload["text"]?.stringValue } }
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
