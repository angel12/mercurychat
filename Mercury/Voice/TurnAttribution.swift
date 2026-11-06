import MercuryKit

/// Which `message.*` turns on a shared session belong to this voice
/// conversation (spec "Revision: authority wire").
///
/// A prompt sent while another turn runs is admitted `queued` (session
/// authority) or `forwarded` (legacy wire). The kit's `AgentTurnTracker`
/// treats every `message.*` as its own turn, so without this it would speak
/// the turn the prompt is queued behind, end on that turn's complete and say
/// the real reply one utterance late. The controller asks `classify` about
/// each turn event and feeds the tracker only the ones that are its own.
///
/// Authority wire order (hermes v0.23):
/// - A claim publishes the turn's `message.start` FIRST, then the `pending`
///   list showing the claimed row `started` (`_stamp_claim`). So while our
///   row is queued, a start opens a buffer of that turn's events and the next
///   list decides it: our row listed `started` (not steering) → our claim,
///   flush the buffer; still queued, or gone → not ours, discard it.
/// - A steer (`prompt.steer_queued`) lists our row `started` + `steering` at
///   once: our text is in the running turn, whose remaining output is ours.
///   Its `steered` settle comes after that turn's own complete. An
///   undelivered steer lists the row `queued` again.
/// - A cancel publishes the list (row gone) FIRST, then the row's
///   `message.complete {admission_id, outcome: cancelled}`.
/// - `cancelled`/`steered` settles retire rows; they are never a turn's end.
///
/// Legacy `forwarded` (no admission ids, no queue): everything until the next
/// `message.start` belongs to the turn ahead; that start is ours.
///
/// Envelope-level `admission_id` would attribute frames exactly, but
/// MercuryKit 0.9.0's `GatewayEvent` does not keep it (parked kit follow-up).
/// One `ownAdmissionID`: a second queued voice prompt replaces the first
/// (parked; the earlier reply may go unspoken).
struct TurnAttribution {
    enum Phase: Equatable {
        /// Our turn (or a turn we did not submit through the queue) is
        /// running: feed everything.
        case open
        /// Authority: our admission is queued (or `unknown`). `seenQueued`
        /// once a `pending` list has shown it, so a later list without it
        /// means it left the queue rather than that the list predates it.
        case queued(seenQueued: Bool)
        /// Our admission left the queue with no claim of ours seen (a
        /// cancel/steer settle decides), or the legacy `forwarded` wait: the
        /// next `message.start` is ours.
        case awaitingOurStart
        /// The turn our admission ran in has completed: later turns on the
        /// session are other apps' claims. Ends at our next submit.
        case finished
    }

    enum Verdict: Equatable {
        /// Ours: hand it to the tracker.
        case feed
        /// Not for the tracker now: someone else's turn, or held in the
        /// claim buffer until the next `pending` list.
        case hold
        /// A queued row's retirement (`cancelled` / `steered`) that is not a
        /// turn of ours ending — not even a turn.
        case retiredRow
        /// Our still-queued prompt was cancelled elsewhere: it will never run.
        case ownQueuedPromptCancelled
        /// Our row was steered into a turn whose steering list we never saw
        /// (it settles after that turn's complete): our turn is already over.
        case ownTurnAlreadyOver
    }

    private(set) var phase: Phase = .open
    /// The admission our latest submit was given (authority only).
    private(set) var ownAdmissionID: String?
    /// While queued: the turn events since a `message.start`, awaiting the
    /// `pending` list that says whose turn it is.
    private var claimBuffer: [GatewayEvent]?
    /// The latest `pending` list, kept for a receipt that lands after it.
    private var lastQueue: [QueuedPrompt]?

    /// Shown as "Waiting for the current turn".
    var isWaiting: Bool {
        switch phase {
        case .queued, .awaitingOurStart: return true
        case .open, .finished: return false
        }
    }

    /// Our prompt is admitted but has not started: a tracker reset must
    /// leave the turn busy, or the engine re-arms the mic before the reply.
    var holdsQueuedPrompt: Bool {
        if case .queued = phase { return true }
        return false
    }

    private static let retiringOutcomes: Set<String> = ["cancelled", "steered"]

    /// Rows a still-queued admission can show: `unknown` (the owner restarted
    /// and can't tell whether it ran) keeps waiting, with no extra UI.
    private static func stillWaiting(_ row: QueuedPrompt) -> Bool {
        row.status == .queued || row.status == .unknown
    }

    /// A submit's outcome; nil when it threw (nothing of ours waits).
    mutating func noteReceipt(_ receipt: PromptSubmission?) {
        claimBuffer = nil
        guard let receipt else {
            phase = .open
            ownAdmissionID = nil
            return
        }
        // A steer joins the running turn: its output is ours, and that
        // turn's admission is not ours to match.
        ownAdmissionID = receipt.status == "steered" ? nil : receipt.admissionID
        if receipt.status == "queued", let admission = receipt.admissionID {
            guard let row = lastQueue?.first(where: { $0.admissionID == admission }) else {
                phase = .queued(seenQueued: false)
                return
            }
            if Self.stillWaiting(row) {
                phase = .queued(seenQueued: true)
            } else if row.steering || row.status == .started {
                // Steered in, or already claimed: our start has passed.
                phase = .open
            } else {
                phase = .awaitingOurStart
            }
        } else if receipt.forwarded || receipt.status == "queued" {
            phase = .awaitingOurStart
        } else {
            phase = .open
        }
    }

    /// A submit is going out: a finished turn's gate must not hold its
    /// events (its receipt may land after its start).
    mutating func noteSubmitInFlight() {
        if phase == .finished { phase = .open }
    }

    /// `session.info.pending`. Returns the buffered events to feed the
    /// tracker, in order, when this list shows the buffered claim is ours.
    mutating func noteQueue(_ rows: [QueuedPrompt]) -> [GatewayEvent] {
        decide(rows, fromSnapshot: false)
    }

    /// A reconnect resume's snapshot. A `pending` list decides a buffered
    /// claim and the wait like a live list; without one the state stands
    /// until the next `session.info`.
    mutating func noteResume(queue rows: [QueuedPrompt]?) -> [GatewayEvent] {
        guard let rows else { return [] }
        return decide(rows, fromSnapshot: true)
    }

    private mutating func decide(_ rows: [QueuedPrompt], fromSnapshot: Bool) -> [GatewayEvent] {
        lastQueue = rows
        let buffered = claimBuffer
        claimBuffer = nil
        guard let admission = ownAdmissionID else { return [] }
        let row = rows.first { $0.admissionID == admission }
        switch phase {
        case .queued(let seenQueued):
            guard let row else {
                // Gone: our claim would list us `started`, so a buffered start
                // was someone else's. Our cancel/steer settle decides.
                if seenQueued || buffered != nil || fromSnapshot { phase = .awaitingOurStart }
                return []
            }
            if Self.stillWaiting(row) {
                phase = .queued(seenQueued: true)
                return []
            }
            if row.steering {
                // Our text is going into the running turn: its output is ours.
                phase = .open
                return []
            }
            guard row.status == .started else {
                phase = .awaitingOurStart
                return []
            }
            // Listed `started` right behind a claim's start: that claim is
            // ours. Without a buffer our start already passed.
            phase = .open
            return buffered ?? []
        case .open, .awaitingOurStart, .finished:
            if let row, Self.stillWaiting(row) {
                // An undelivered steer went back to its queue place.
                phase = .queued(seenQueued: true)
            } else if let row, row.steering, phase == .awaitingOurStart {
                phase = .open
            }
            return []
        }
    }

    /// The tracker was reset from a snapshot (no replay): whatever turn it
    /// shows is the session's state now, so only a still-queued prompt of
    /// ours keeps the gate.
    mutating func noteTrackerReset() {
        claimBuffer = nil
        if !holdsQueuedPrompt { phase = .open }
    }

    mutating func classify(_ event: GatewayEvent) -> Verdict {
        let isStart = event.type == GatewayEvent.Kind.messageStart

        if event.type == GatewayEvent.Kind.messageComplete,
            let outcome = event.payload["outcome"]?.stringValue,
            Self.retiringOutcomes.contains(outcome),
            let admission = event.payload["admission_id"]?.stringValue
        {
            guard admission == ownAdmissionID else { return .retiredRow }
            switch phase {
            case .queued, .awaitingOurStart:
                claimBuffer = nil
                ownAdmissionID = nil
                if outcome == "cancelled" {
                    phase = .open
                    return .ownQueuedPromptCancelled
                }
                phase = .finished
                return .ownTurnAlreadyOver
            case .open where outcome == "cancelled":
                break  // ours was running: the cancel interrupted it — its end
            case .open, .finished:
                // A steered settle trails the turn our text ran in.
                return .retiredRow
            }
        }

        switch phase {
        case .open:
            if event.type == GatewayEvent.Kind.messageComplete, ownAdmissionID != nil {
                // The turn our admission ran in ended: later claims are not ours.
                phase = .finished
            }
            return .feed
        case .finished:
            return .hold
        case .queued:
            // A start that names our admission is ours whatever the queue
            // last said.
            if isStart, let admission = ownAdmissionID,
                event.payload["admission_id"]?.stringValue == admission
            {
                phase = .open
                claimBuffer = nil
                return .feed
            }
            if isStart {
                // A new claim: whatever an earlier start buffered ended
                // without a list releasing our row, so it was not ours.
                claimBuffer = [event]
            } else if claimBuffer != nil {
                claimBuffer?.append(event)
            }
            return .hold
        case .awaitingOurStart:
            guard isStart else { return .hold }
            phase = .open
            return .feed
        }
    }
}
