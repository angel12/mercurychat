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
///   `session.info.pending`. While the row is queued (or has not been seen
///   leaving the queue) turn events are someone else's; once it has started
///   or left the queue, the next `message.start` is ours.
/// - Legacy `forwarded` (no admission ids, no queue): if a turn was running
///   when we submitted, that turn is foreign until its `message.complete`,
///   and the next `message.start` is ours.
/// - A `message.complete {outcome: cancelled, admission_id}` retires a row
///   that never ran. Ours (still queued) means our prompt will never run;
///   anyone else's never touches the tracker.
struct TurnAttribution: Equatable {
    enum Phase: Equatable {
        /// Every turn event is ours (or nothing of ours is pending).
        case open
        /// Authority: our admission is queued. `seenQueued` once a
        /// `pending` list has shown it, so a later list without it means it
        /// left the queue rather than that the list predates it.
        case queued(seenQueued: Bool)
        /// Our admission started or left the queue: the next `message.start`
        /// is ours; anything before it is the turn ahead finishing.
        case released
        /// Legacy `forwarded`: the running turn is foreign until its complete.
        case skippingRunningTurn
        /// Legacy `forwarded`: the next `message.start` is ours.
        case awaitingNextStart
    }

    enum Verdict: Equatable {
        /// Ours: hand it to the tracker.
        case feed
        /// Someone else's turn: the tracker must not see it.
        case drop
        /// A row that never ran was cancelled — not ours, not a turn's end.
        case dropCancelledRow
        /// Our still-queued prompt was cancelled elsewhere: it will never run.
        case ownQueuedPromptCancelled
    }

    private(set) var phase: Phase = .open
    /// The admission our latest submit was given (authority only).
    private(set) var ownAdmissionID: String?
    /// A `message.start` was seen without its `message.complete`.
    private(set) var turnInProgress = false
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

    /// A submit's outcome; nil when it threw (nothing of ours waits).
    /// `turnWasRunning` is `turnInProgress` as the submit went out, for a
    /// non-barge-in submit.
    mutating func noteReceipt(_ receipt: PromptSubmission?, turnWasRunning: Bool) {
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
                phase = row.status == .queued ? .queued(seenQueued: true) : .released
            } else {
                phase = .queued(seenQueued: false)
            }
        } else if receipt.forwarded || receipt.status == "queued" {
            phase = turnWasRunning ? .skippingRunningTurn : .awaitingNextStart
        } else {
            phase = .open
        }
    }

    /// `session.info.pending` (or a resume snapshot's `pending`).
    mutating func noteQueue(_ rows: [QueuedPrompt]) {
        lastQueue = rows
        guard let admission = ownAdmissionID else { return }
        switch phase {
        case .queued(let seenQueued):
            if let row = rows.first(where: { $0.admissionID == admission }) {
                phase = row.status == .queued ? .queued(seenQueued: true) : .released
            } else if seenQueued {
                phase = .released
            }
        default:
            break
        }
    }

    /// A reconnect resume's snapshot. A `pending` list re-derives the wait
    /// (our row still queued, or started/gone so the next start is ours);
    /// without one the state stands until the next `session.info`.
    mutating func noteResume(queue rows: [QueuedPrompt]?) {
        guard let rows, let admission = ownAdmissionID else { return }
        lastQueue = rows
        switch phase {
        case .queued, .released:
            let row = rows.first { $0.admissionID == admission }
            phase = row?.status == .queued ? .queued(seenQueued: true) : .released
        default:
            break
        }
    }

    /// The tracker was reset from a snapshot (no replay): whatever turn it
    /// shows is the session's state now, so only a still-queued prompt of
    /// ours keeps the gate.
    mutating func noteTrackerReset(running: Bool) {
        turnInProgress = running
        if !holdsQueuedPrompt { phase = .open }
    }

    mutating func classify(_ event: GatewayEvent) -> Verdict {
        let isStart = event.type == GatewayEvent.Kind.messageStart
        let isComplete = event.type == GatewayEvent.Kind.messageComplete

        if isComplete, event.payload["outcome"]?.stringValue == "cancelled",
            let admission = event.payload["admission_id"]?.stringValue
        {
            guard admission == ownAdmissionID else { return .dropCancelledRow }
            switch phase {
            case .queued, .released:
                phase = .open
                ownAdmissionID = nil
                return .ownQueuedPromptCancelled
            default:
                break  // ours was running: this is its end
            }
        }

        if isStart { turnInProgress = true }
        if isComplete { turnInProgress = false }

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
                return .feed
            }
            return .drop
        case .released, .awaitingNextStart:
            guard isStart else { return .drop }
            phase = .open
            return .feed
        case .skippingRunningTurn:
            if isComplete {
                phase = .awaitingNextStart
                return .drop
            }
            // A second start means the foreign turn's complete never came:
            // the turn that follows it is ours.
            guard isStart else { return .drop }
            phase = .open
            return .feed
        }
    }
}
