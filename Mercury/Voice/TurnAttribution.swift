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
/// - Authority: the receipt's `admission_id` is followed through
///   `session.info.pending`. When the authority claims a row it publishes the
///   turn's `message.start` FIRST and the `pending` list that shows the row
///   started (or gone) right after it (hermes v0.23 `_stamp_claim`). So while
///   our row is queued, a `message.start` opens a buffer of that turn's
///   events; the next `pending` list decides: our row left the queue → the
///   turn is ours, flush the buffer to the tracker; our row still queued →
///   it was someone else's turn, discard it.
/// - Legacy `forwarded` (no admission ids, no queue): everything until the
///   next `message.start` belongs to the turn ahead; that start is ours.
/// - `message.complete {admission_id, outcome: cancelled | steered}` retires
///   a queued row (the authority publishes it after the `pending` list). It
///   is never a turn's end. Ours cancelled: our prompt will never run. Ours
///   steered: our text joined the running turn, whose output is now ours.
///
/// Envelope-level `admission_id` would attribute frames exactly, but
/// MercuryKit 0.9.0's `GatewayEvent` does not keep it (parked kit follow-up).
struct TurnAttribution {
    enum Phase: Equatable {
        /// Every turn event is ours (or nothing of ours is pending).
        case open
        /// Authority: our admission is queued (or `unknown`). `seenQueued`
        /// once a `pending` list has shown it, so a later list without it
        /// means it left the queue rather than that the list predates it.
        case queued(seenQueued: Bool)
        /// Our admission left the queue with no turn start seen yet, or the
        /// legacy `forwarded` wait: the next `message.start` is ours.
        case awaitingOurStart
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
    var isWaiting: Bool { phase != .open }

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
            if let row = lastQueue?.first(where: { $0.admissionID == admission }) {
                phase = Self.stillWaiting(row) ? .queued(seenQueued: true) : .awaitingOurStart
            } else {
                phase = .queued(seenQueued: false)
            }
        } else if receipt.forwarded || receipt.status == "queued" {
            phase = .awaitingOurStart
        } else {
            phase = .open
        }
    }

    /// `session.info.pending`. Returns the buffered events to feed the
    /// tracker, in order, when this list shows the buffered turn is ours.
    mutating func noteQueue(_ rows: [QueuedPrompt]) -> [GatewayEvent] {
        lastQueue = rows
        let buffered = claimBuffer
        claimBuffer = nil
        guard case .queued(let seenQueued) = phase, let admission = ownAdmissionID else {
            return []
        }
        let row = rows.first { $0.admissionID == admission }
        if let row, Self.stillWaiting(row) {
            // Still queued: a buffered start was someone else's claim.
            phase = .queued(seenQueued: true)
            return []
        }
        if let buffered {
            // The list right behind a claim's start no longer queues our row:
            // that claim was ours.
            phase = .open
            return buffered
        }
        if row != nil || seenQueued {
            // Started, or gone (a cancel/steer settle may follow): the next
            // start is ours.
            phase = .awaitingOurStart
        }
        return []
    }

    /// A reconnect resume's snapshot. A `pending` list re-derives the wait
    /// (our row still queued, or started/gone so the next start is ours);
    /// without one the state stands until the next `session.info`.
    mutating func noteResume(queue rows: [QueuedPrompt]?) {
        claimBuffer = nil
        guard let rows, let admission = ownAdmissionID else { return }
        lastQueue = rows
        switch phase {
        case .queued, .awaitingOurStart:
            let row = rows.first { $0.admissionID == admission }
            phase = row.map(Self.stillWaiting) == true ? .queued(seenQueued: true) : .awaitingOurStart
        case .open:
            break
        }
    }

    /// The tracker was reset from a snapshot (no replay): whatever turn it
    /// shows is the session's state now, so only a still-queued prompt of
    /// ours keeps the gate.
    mutating func noteTrackerReset() {
        claimBuffer = nil
        if !holdsQueuedPrompt { phase = .open }
    }

    /// The socket dropped: a half-seen claim can't be decided any more.
    mutating func noteConnectionLost() {
        claimBuffer = nil
    }

    mutating func classify(_ event: GatewayEvent) -> Verdict {
        let isStart = event.type == GatewayEvent.Kind.messageStart

        if event.type == GatewayEvent.Kind.messageComplete,
            let outcome = event.payload["outcome"]?.stringValue,
            Self.retiringOutcomes.contains(outcome),
            let admission = event.payload["admission_id"]?.stringValue
        {
            guard admission == ownAdmissionID else { return .retiredRow }
            switch (outcome, phase) {
            case ("cancelled", .open):
                // Ours was running: the cancel interrupted it — its end.
                break
            case ("cancelled", _):
                phase = .open
                ownAdmissionID = nil
                claimBuffer = nil
                return .ownQueuedPromptCancelled
            default:
                // Steered: our text joined the running turn. Its remaining
                // output and its real complete are ours from here.
                phase = .open
                ownAdmissionID = nil
                claimBuffer = nil
                return .retiredRow
            }
        }

        switch phase {
        case .open:
            return .feed
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
