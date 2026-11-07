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
/// Exact attribution (MercuryKit 0.10.0 `GatewayEvent.admissionID`): an
/// authority stamps every frame of a claimed admission with its id, so once a
/// frame carries one the order rules above give way to it. A frame whose id is
/// one of ours (or the turn our prompt was steered into) is fed; any other id
/// is held. Turn ends are matched by id too: cancelling a still-queued
/// admission publishes a `message.complete` stamped with that admission's id,
/// possibly while another turn runs. Every queued voice prompt is tracked, so
/// a second one no longer replaces the first. Frames without an id (idle
/// fanouts, a reconnect's first frames, the legacy wire) still go through the
/// order rules.
///
/// On an authority voice speaks only replies to its own prompts, so its idle
/// phase there is `.finished`, not `.open`: at session open, after a tracker
/// reset with no turn of ours running, after our queued prompt is cancelled
/// and after a failed submit. Other apps' turns are then held, never fed —
/// never spoken, never a reason to arm barge-in. A submit reopens as usual.
/// The legacy wire has no attribution, so its idle phase stays `.open`.
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
    /// The socket speaks the session-authority wire (the connection's
    /// `isSessionAuthority`, read at open and at each reconnect resume).
    private(set) var onAuthority = false
    /// The admission our latest submit was given (authority only).
    private(set) var ownAdmissionID: String?
    /// While queued: the turn events since a `message.start`, awaiting the
    /// `pending` list that says whose turn it is.
    private var claimBuffer: [GatewayEvent]?
    /// The latest `pending` list, kept for a receipt that lands after it.
    private var lastQueue: [QueuedPrompt]?

    // MARK: Exact attribution state (frames stamped with `admissionID`)

    /// An authority frame carried an admission id: attribution goes by id.
    private(set) var exact = false
    /// Our admissions that have not finished: queued, or running.
    private(set) var ownAdmissions: Set<String> = []
    /// Our admissions steered into another turn, kept until their `steered`
    /// settle retires the row.
    private var steeredAdmissions: Set<String> = []
    /// The admission the running turn belongs to, from its frames.
    private(set) var runningAdmission: String?
    /// The turn one of our prompts was steered into: its output is ours.
    private var joinedAdmission: String?
    /// Steered in before any frame named the running turn: the next stamped
    /// frame says which turn we joined.
    private var joinNextRunning = false
    /// While a submit is in flight: frames of admissions we can't place yet,
    /// by id. The receipt names ours (its turn can start before the receipt).
    private var unplaced: [String: [GatewayEvent]] = [:]
    private var submitInFlight = false
    private static let unplacedCap = 2_000

    /// Shown as "Waiting for the current turn".
    var isWaiting: Bool {
        switch phase {
        case .queued, .awaitingOurStart: return true
        case .open, .finished: return false
        }
    }

    /// The turn the tracker is running (if any) is ours to cut short: only
    /// while our own turn runs or our submit is going out. Waiting behind
    /// another turn, `.finished`, or idle on an authority, `session.interrupt`
    /// would stop another app's turn.
    var mayInterrupt: Bool { phase == .open }

    /// No turn of ours is running: other apps' turns are not ours to hear.
    private var idlePhase: Phase { onAuthority ? .finished : .open }

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

    /// A session was opened on a socket that does (or does not) speak the
    /// authority wire: nothing of ours runs yet.
    mutating func noteSessionOpened(authority: Bool) {
        onAuthority = authority
        claimBuffer = nil
        clearExact()
        phase = idlePhase
    }

    private mutating func clearExact() {
        exact = false
        ownAdmissions = []
        steeredAdmissions = []
        runningAdmission = nil
        joinedAdmission = nil
        joinNextRunning = false
        unplaced = [:]
        submitInFlight = false
    }

    /// A reconnect landed on a socket that does (or does not) speak the
    /// authority wire. `.finished` has no meaning without admission ids.
    mutating func noteWire(authority: Bool) {
        onAuthority = authority
        if !authority {
            clearExact()
            if phase == .finished { phase = .open }
        }
    }

    /// A submit's outcome; nil when it threw (nothing of ours waits).
    /// Returns frames of our admission that landed before the receipt (exact
    /// attribution only), to feed the tracker in order.
    @discardableResult
    mutating func noteReceipt(_ receipt: PromptSubmission?) -> [GatewayEvent] {
        if exact { return noteExactReceipt(receipt) }
        noteOrderReceipt(receipt)
        return []
    }

    private mutating func noteOrderReceipt(_ receipt: PromptSubmission?) {
        claimBuffer = nil
        submitInFlight = false
        unplaced = [:]
        if let admission = receipt?.admissionID, receipt?.status != "steered" {
            // Kept for when stamped frames start arriving.
            ownAdmissions.insert(admission)
        }
        guard let receipt else {
            phase = idlePhase
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
        submitInFlight = true
        if exact { return }  // unplaced frames wait for the receipt instead
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
        if exact {
            decideExact(rows)
            return []
        }
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
            } else if let row, phase == .awaitingOurStart,
                row.steering || row.status == .started
            {
                // Steered in, or our claim already passed (a reconnect after
                // its buffered start, a replayed list): the turn is ours.
                phase = .open
            }
            return []
        }
    }

    /// The tracker is being reset from a snapshot (no replay): whatever turn
    /// it shows is the session's state now, so only a still-queued prompt of
    /// ours keeps the gate. Returns whether the snapshot's `running` turn is
    /// the tracker's to follow (its `busy` seed). On an authority that is
    /// only a turn of ours already running (or released to us) before the
    /// outage; anything else is another app's and is held.
    mutating func noteTrackerReset(running: Bool) -> Bool {
        claimBuffer = nil
        if exact {
            unplaced = [:]
            if !running {
                runningAdmission = nil
                joinedAdmission = nil
            }
            recomputeExactPhase()
            return running && phase == .open
        }
        if holdsQueuedPrompt { return false }
        guard onAuthority else {
            phase = .open
            return running
        }
        if running, phase == .open || phase == .awaitingOurStart {
            phase = .open
            return true
        }
        phase = .finished
        return false
    }

    mutating func classify(_ event: GatewayEvent) -> Verdict {
        if onAuthority, let admission = event.admissionID {
            if !exact { enterExact() }
            return classifyExact(event, admission: admission)
        }
        return classifyByOrder(event)
    }

    private mutating func classifyByOrder(_ event: GatewayEvent) -> Verdict {
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
                    phase = idlePhase
                    return .ownQueuedPromptCancelled
                }
                phase = .finished
                return .ownTurnAlreadyOver
            case .open where outcome == "cancelled":
                break  // ours was running: the cancel interrupted it — its end
            case .open:
                // A steered settle trails the joined turn's complete, and a
                // fed complete would have moved us to `.finished`: that
                // turn ended unseen, so ours is already over.
                claimBuffer = nil
                ownAdmissionID = nil
                phase = .finished
                return .ownTurnAlreadyOver
            case .finished:
                // A steered settle trails the turn our text ran in.
                return .retiredRow
            }
        }

        switch phase {
        case .open:
            if event.type == GatewayEvent.Kind.messageComplete, ownAdmissionID != nil {
                // The turn our admission ran in ended: later claims are not ours.
                phase = .finished
            } else if onAuthority, event.type == GatewayEvent.Kind.messageComplete {
                // Our turn (a steer's joined turn, say) ended: on an
                // authority the next turn is another app's until we submit.
                // Only `message.complete` ends a turn: hermes raises `error`
                // mid-turn (a model switch needing confirmation, a failed
                // compression) and the turn carries on.
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

    // MARK: Exact attribution

    /// The first stamped frame: whatever the order rules had half-decided is
    /// superseded by the ids from here on.
    private mutating func enterExact() {
        exact = true
        claimBuffer = nil
        if let own = ownAdmissionID { ownAdmissions.insert(own) }
        // A submit in flight opened the gate only so its early frames get
        // through: those now wait for the receipt to name them instead.
        if phase == .open, ownAdmissionID == nil, ownAdmissions.isEmpty, !submitInFlight {
            // A steer (or a turn we didn't submit through the queue) is
            // running: the next stamped frame names the turn we joined.
            joinNextRunning = true
        }
    }

    private func isOurs(_ admission: String) -> Bool {
        ownAdmissions.contains(admission) || admission == joinedAdmission
    }

    private mutating func recomputeExactPhase() {
        if let running = runningAdmission, isOurs(running) {
            phase = .open
        } else if !ownAdmissions.subtracting([runningAdmission].compactMap { $0 }).isEmpty {
            phase = .queued(seenQueued: true)
        } else {
            phase = idlePhase
        }
    }

    private mutating func classifyExact(_ event: GatewayEvent, admission: String) -> Verdict {
        let isComplete = event.type == GatewayEvent.Kind.messageComplete
        let outcome = isComplete ? event.payload["outcome"]?.stringValue : nil
        let settled = event.payload["admission_id"]?.stringValue ?? admission

        if let outcome, Self.retiringOutcomes.contains(outcome), settled != runningAdmission {
            return retireExact(settled, outcome: outcome)
        }

        if joinNextRunning {
            joinNextRunning = false
            joinedAdmission = admission
        }
        runningAdmission = admission

        guard isOurs(admission) else {
            if submitInFlight {
                // Its receipt may yet name it ours.
                var frames = unplaced[admission] ?? []
                if frames.count < Self.unplacedCap { frames.append(event) }
                unplaced[admission] = frames
            }
            if isComplete { runningAdmission = nil }
            recomputeExactPhase()
            return .hold
        }

        if isComplete {
            // Our turn ended (a cancel of our running admission included).
            ownAdmissions.remove(admission)
            if joinedAdmission == admission { joinedAdmission = nil }
            runningAdmission = nil
            ownAdmissionID = ownAdmissions.contains(ownAdmissionID ?? "") ? ownAdmissionID : nil
        }
        recomputeExactPhase()
        return .feed
    }

    /// A queued row's `cancelled` / `steered` settle, matched by id.
    private mutating func retireExact(_ admission: String, outcome: String) -> Verdict {
        let wasQueued = ownAdmissions.remove(admission) != nil
        let wasSteered = steeredAdmissions.remove(admission) != nil
        if ownAdmissionID == admission { ownAdmissionID = nil }
        guard wasQueued || wasSteered else { return .retiredRow }
        let oursRunning = runningAdmission.map(isOurs) ?? false
        recomputeExactPhase()
        if oursRunning || !ownAdmissions.isEmpty {
            // Another turn of ours is running or still waits: no reset.
            return .retiredRow
        }
        if outcome == "cancelled" { return .ownQueuedPromptCancelled }
        // Steered: a joined turn we followed already ended on its own
        // complete; a steer we never saw listed went into a turn we held.
        return wasSteered ? .retiredRow : .ownTurnAlreadyOver
    }

    private mutating func noteExactReceipt(_ receipt: PromptSubmission?) -> [GatewayEvent] {
        submitInFlight = false
        let parked = unplaced
        unplaced = [:]
        guard let receipt else {
            ownAdmissionID = nil
            recomputeExactPhase()
            return []
        }
        var flush: [GatewayEvent] = []
        if receipt.status == "steered" {
            // Our text joins the running turn: its output is ours.
            if let admission = receipt.admissionID { steeredAdmissions.insert(admission) }
            ownAdmissionID = nil
            if let running = runningAdmission {
                joinedAdmission = running
                flush = parked[running] ?? []
            } else {
                joinNextRunning = true
            }
        } else if let admission = receipt.admissionID {
            ownAdmissions.insert(admission)
            ownAdmissionID = admission
            flush = parked[admission] ?? []
            if let row = lastQueue?.first(where: { $0.admissionID == admission }), row.steering {
                markSteered(admission)
            }
        }
        recomputeExactPhase()
        if !flush.isEmpty, flush.last?.type == GatewayEvent.Kind.messageComplete,
            let id = flush.last?.admissionID
        {
            // The whole turn landed before its receipt.
            ownAdmissions.remove(id)
            if joinedAdmission == id { joinedAdmission = nil }
            recomputeExactPhase()
        }
        return flush
    }

    private mutating func markSteered(_ admission: String) {
        ownAdmissions.remove(admission)
        steeredAdmissions.insert(admission)
        if let running = runningAdmission, !isOurs(running) {
            joinedAdmission = running
        } else if runningAdmission == nil {
            joinNextRunning = true
        }
    }

    private mutating func decideExact(_ rows: [QueuedPrompt]) {
        for row in rows {
            let id = row.admissionID
            if ownAdmissions.contains(id), row.steering, id != runningAdmission {
                // Our text is going into the running turn.
                markSteered(id)
            } else if steeredAdmissions.contains(id), Self.stillWaiting(row), !row.steering {
                // An undelivered steer went back to its queue place.
                steeredAdmissions.remove(id)
                ownAdmissions.insert(id)
                if steeredAdmissions.isEmpty { joinedAdmission = nil }
            }
        }
        recomputeExactPhase()
    }
}
