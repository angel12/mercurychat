import MercuryKit
import Testing

/// Turn attribution by the frame's `admissionID` (MercuryKit 0.10.0): once an
/// authority stamps frames, the id decides whose turn a frame belongs to, not
/// the order of starts and `pending` lists.
@Suite struct ExactTurnAttributionTests {
    // MARK: Frames

    private func frame(
        _ type: String, _ admission: String?, _ payload: [String: JSONValue] = [:]
    ) -> GatewayEvent {
        GatewayEvent(
            type: type, sessionID: "runtime", payload: .object(payload), admissionID: admission)
    }

    private func start(_ admission: String) -> GatewayEvent {
        frame(GatewayEvent.Kind.messageStart, admission)
    }

    private func delta(_ admission: String) -> GatewayEvent {
        frame(GatewayEvent.Kind.messageDelta, admission, ["text": .string("x")])
    }

    private func complete(_ admission: String) -> GatewayEvent {
        frame(GatewayEvent.Kind.messageComplete, admission, ["text": .string("done")])
    }

    /// A queued row's settle: stamped with that row's id, beside a turn
    /// that may be running under another id.
    private func settled(_ admission: String, _ outcome: String) -> GatewayEvent {
        frame(
            GatewayEvent.Kind.messageComplete, admission,
            ["admission_id": .string(admission), "outcome": .string(outcome)])
    }

    private func rows(_ rows: (String, String, Bool)...) -> [QueuedPrompt] {
        let json: [JSONValue] = rows.enumerated().map { index, row in
            .object([
                "admission_id": .string(row.0), "sequence": .number(Double(index)),
                "text": .string("p"), "status": .string(row.1), "steering": .bool(row.2),
            ])
        }
        return QueuedPrompt.list(from: .object(["pending": .array(json)])) ?? []
    }

    private func opened() -> TurnAttribution {
        var attribution = TurnAttribution()
        attribution.noteSessionOpened(authority: true)
        return attribution
    }

    private func queued(_ admission: String) -> PromptSubmission {
        PromptSubmission(status: "queued", admissionID: admission)
    }

    // MARK: Tests

    @Test func aForeignTurnIsHeldWhileOursWaitsAndOurStartIsFedWithoutAList() {
        var a = opened()
        a.noteReceipt(queued("mine"))
        #expect(a.classify(start("theirs")) == .hold)
        #expect(a.classify(delta("theirs")) == .hold)
        #expect(a.isWaiting)
        #expect(a.classify(complete("theirs")) == .hold)
        #expect(a.classify(start("mine")) == .feed)
        #expect(a.mayInterrupt)
        #expect(a.classify(complete("mine")) == .feed)
        #expect(a.phase == .finished)
    }

    @Test func twoQueuedVoicePromptsAreBothSpoken() {
        var a = opened()
        a.noteReceipt(queued("first"))
        a.noteReceipt(queued("second"))
        #expect(a.classify(start("first")) == .feed)
        #expect(a.classify(complete("first")) == .feed)
        // The second still waits: not idle, not open.
        #expect(a.holdsQueuedPrompt)
        #expect(a.classify(start("other")) == .hold)
        #expect(a.classify(complete("other")) == .hold)
        #expect(a.classify(start("second")) == .feed)
        #expect(a.classify(complete("second")) == .feed)
        #expect(a.phase == .finished)
    }

    @Test func cancellingOurQueuedPromptWhileAnotherTurnRunsGoesIdle() {
        var a = opened()
        a.noteReceipt(queued("mine"))
        #expect(a.classify(start("theirs")) == .hold)
        #expect(a.classify(settled("mine", "cancelled")) == .ownQueuedPromptCancelled)
        #expect(!a.isWaiting)
        // The running turn's frames and end stay someone else's.
        #expect(a.classify(delta("theirs")) == .hold)
        #expect(a.classify(complete("theirs")) == .hold)
    }

    @Test func cancellingOurSecondPromptDoesNotStopOurRunningTurn() {
        var a = opened()
        a.noteReceipt(queued("first"))
        a.noteReceipt(queued("second"))
        #expect(a.classify(start("first")) == .feed)
        #expect(a.classify(settled("second", "cancelled")) == .retiredRow)
        #expect(a.mayInterrupt)
        #expect(a.classify(delta("first")) == .feed)
        #expect(a.classify(complete("first")) == .feed)
        #expect(a.phase == .finished)
    }

    @Test func aForeignSettleWhileOurTurnRunsIsARetiredRow() {
        var a = opened()
        a.noteReceipt(PromptSubmission(status: "started", admissionID: "mine"))
        #expect(a.classify(start("mine")) == .feed)
        #expect(a.classify(settled("theirs", "cancelled")) == .retiredRow)
        #expect(a.classify(settled("theirs2", "steered")) == .retiredRow)
        #expect(a.classify(complete("mine")) == .feed)
    }

    @Test func ourTurnThatStartsBeforeItsReceiptIsFedAtTheReceipt() {
        var a = opened()
        a.noteSubmitInFlight()
        #expect(a.classify(start("mine")) == .hold)
        #expect(a.classify(delta("mine")) == .hold)
        let flushed = a.noteReceipt(PromptSubmission(status: "started", admissionID: "mine"))
        #expect(flushed.map(\.type) == [GatewayEvent.Kind.messageStart, GatewayEvent.Kind.messageDelta])
        #expect(a.mayInterrupt)
        #expect(a.classify(complete("mine")) == .feed)
        #expect(a.phase == .finished)
    }

    @Test func anotherAppsTurnDuringOurSubmitIsNotFlushed() {
        var a = opened()
        a.noteSubmitInFlight()
        #expect(a.classify(start("theirs")) == .hold)
        let flushed = a.noteReceipt(queued("mine"))
        #expect(flushed.isEmpty)
        #expect(a.isWaiting)
    }

    @Test func aSteeredReceiptJoinsTheRunningTurn() {
        var a = opened()
        #expect(a.classify(start("theirs")) == .hold)
        a.noteSubmitInFlight()
        #expect(a.classify(delta("theirs")) == .hold)
        let flushed = a.noteReceipt(PromptSubmission(status: "steered", admissionID: "mine"))
        #expect(flushed.count == 1)
        #expect(a.mayInterrupt)
        #expect(a.classify(delta("theirs")) == .feed)
        #expect(a.classify(complete("theirs")) == .feed)
        #expect(a.phase == .finished)
        // The steered row's settle trails the turn it joined.
        #expect(a.classify(settled("mine", "steered")) == .retiredRow)
        #expect(a.classify(start("next")) == .hold)
    }

    @Test func aQueuedRowListedSteeringJoinsTheRunningTurn() {
        var a = opened()
        a.noteReceipt(queued("mine"))
        #expect(a.classify(start("theirs")) == .hold)
        _ = a.noteQueue(rows(("theirs", "started", false), ("mine", "started", true)))
        #expect(a.mayInterrupt)
        #expect(a.classify(delta("theirs")) == .feed)
        #expect(a.classify(complete("theirs")) == .feed)
        #expect(a.classify(settled("mine", "steered")) == .retiredRow)
        #expect(a.phase == .finished)
    }

    @Test func aSteerSettledInATurnWeHeldIsAlreadyOver() {
        var a = opened()
        a.noteReceipt(queued("mine"))
        #expect(a.classify(start("theirs")) == .hold)
        #expect(a.classify(complete("theirs")) == .hold)
        #expect(a.classify(settled("mine", "steered")) == .ownTurnAlreadyOver)
        #expect(!a.isWaiting)
    }

    @Test func unstampedFramesStillUseTheOrderRules() {
        var a = opened()
        a.noteReceipt(PromptSubmission(status: "queued", admissionID: "mine"))
        let unstampedStart = GatewayEvent(
            type: GatewayEvent.Kind.messageStart, sessionID: "runtime", payload: .object([:]))
        #expect(a.classify(unstampedStart) == .hold)
        #expect(!a.exact)
    }

    @Test func theLegacyWireIgnoresIDs() {
        var a = TurnAttribution()
        a.noteSessionOpened(authority: false)
        #expect(a.classify(start("anything")) == .feed)
        #expect(!a.exact)
    }
}
