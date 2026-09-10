import ChatCore
import Foundation
import MercuryKit
import Observation
import os

/// Owns one open session on the shared connection: create/resume, transcript
/// hydration, live event routing into the `TranscriptStore`, prompt
/// submission, and blocking-prompt responses.
@MainActor
@Observable
final class ChatController: Identifiable {
    enum Mode {
        case create(cwd: String?, title: String?)
        case resume(SessionSummary)
        /// A bot's canonical Bot Chat, resolved AT OPEN TIME by the exact-title
        /// registry lookup — never from a cached roster row, which can be
        /// stale (created moments ago on this device inside the roster
        /// throttle, or created by another client since the listing).
        /// `expectCanonical` carries the roster's last positive confirmation:
        /// when it saw a canonical chat but the lookup comes back empty, the
        /// open fails closed instead of minting a duplicate forever-chat.
        case bot(profile: String, expectCanonical: Bool)
    }

    let id = UUID()
    let store = TranscriptStore()

    /// Runtime id — what RPCs take; recycled on backend restart.
    private(set) var runtimeID: String?
    /// Durable id — what resume/hydration take; re-anchored on every resume.
    private(set) var storedID: String?
    private(set) var handle: SessionHandle?
    private(set) var isLoading = false
    private(set) var canLoadOlder = false
    var errorMessage: String?
    /// Transcript history couldn't be fetched (initial hydration or an
    /// older page). Tracked separately from `errorMessage` so the retry
    /// affordance survives unrelated errors and vice versa.
    private(set) var historyError: String?

    private let connection: HermesConnection
    private let profile: String?

    /// This chat is a bot's canonical Bot Chat — a forever-chat that must
    /// never fork. The composer path reroutes `/new` and `/reset` to
    /// `/compact` (BotChatPolicy); regular sessions keep full `/new` freedom.
    var isCanonicalBotChat = false
    private static let logger = Logger(subsystem: "Mercury", category: "ChatController")
    /// Older-history paging state (order=latest offsets count back from the
    /// newest row).
    private var loadedOffset = 0
    private static let pageSize = 100

    /// Profile the current session was actually resumed under
    /// (`session.profile` wins over the controller default) — retry and
    /// older-page fetches must hit the same profile store as hydration.
    private var effectiveProfile: String?

    /// Monotonic guard for resume/create flows: `begin` suspends across the
    /// resume RPC and hydration, and a reconnect starts another `begin`
    /// mid-flight — only the newest generation may publish handle, ids,
    /// transcript pages, or inflight state (mirrors AppModel.connectGeneration).
    private var beginGeneration = 0

    // MARK: Event-replay bookkeeping (v0.20.5+ reconnect contract)

    /// Highest `seq` applied to the store. Session events are stamped with a
    /// per-session monotonic seq; the server buffers the last 512 (even
    /// while our socket is down) and replays the gap via
    /// `session.events.since`. nil = backend doesn't stamp (pre-0.20.5) or
    /// the epoch changed — full resume+rehydrate is the only path then.
    private var lastSeenSeq: Int?
    /// Process identity of the seq numbering, learned from `gateway.ready`.
    /// A different epoch on reconnect = gateway restart = watermark void.
    private var replayEpoch: String?
    /// While a replay is being fetched, live events park here so the gap
    /// events apply first (seq dedupe drops any overlap on drain).
    private var replayBuffer: [GatewayEvent] = []
    private var isReplaying = false

    /// Attachments for echoes still in flight or failed, keyed by echo id, so
    /// a retry re-uploads the same bytes. The failure path always detaches
    /// staged images server-side, so re-attaching on retry never doubles up.
    private var pendingUploads: [String: [PendingAttachment]] = [:]

    /// Serializes sends. `dispatch` suspends across attach RPCs, and the
    /// server drains ALL staged images into whichever prompt.submit lands
    /// first — an interleaved second send (even text-only) would steal the
    /// first send's attachments. Each dispatch awaits the previous one.
    private var sendQueue: Task<Void, Never>?

    init(connection: HermesConnection, profile: String?) {
        self.connection = connection
        self.profile = profile
    }

    // MARK: Lifecycle

    /// Set when AppModel discards this controller (disconnect, closeChat).
    /// The sole begin() caller is a `.task` body that runs on a later
    /// MainActor hop, so the discard can land first (#48's surviving race) —
    /// a begin() after that must not dial RPCs on a stopped (or stopping)
    /// connection: it would surface a spurious error at best, and at worst
    /// win the race against the async `connection.stop()` and open a
    /// server-side runtime session nothing ever tears down.
    private(set) var isInvalidated = false

    /// One-way: the controller never comes back — ChatView builds a fresh
    /// one per session. Bumping the generation also bars a begin() already
    /// suspended mid-RPC from publishing its results.
    func invalidate() {
        isInvalidated = true
        beginGeneration += 1
    }

    func begin(_ mode: Mode) async {
        guard !isInvalidated else { return }
        beginGeneration += 1
        let generation = beginGeneration
        // A resume supersedes any text buffered or held from the previous
        // socket — the resume payload's inflight snapshot carries the whole
        // turn, so replaying stale events after it would duplicate content.
        pendingMessageText = ""
        pendingReasoningText = ""
        heldEvents = []
        transcriptHoldActive = false
        isLoading = true
        defer { if generation == beginGeneration { isLoading = false } }
        do {
            switch mode {
            case .create(let cwd, let title):
                let handle = try await connection.createSession(
                    cwd: cwd, profile: profile, title: title)
                guard generation == beginGeneration else { return }
                adopt(handle)

            case .bot(let profile, let expectCanonical):
                // FAIL CLOSED on lookup failure: a failed registry check must
                // never read as "no Bot Chat exists" — creating on that
                // misreading is exactly how a forever-chat forks. The error
                // surfaces with the standard retry affordance.
                guard let existing = try await resolveCanonicalChat(
                    profile: profile, expectCanonical: expectCanonical)
                else {
                    guard generation == beginGeneration else { return }
                    // Confirmed absence: this bot never had a Bot Chat. Mint
                    // it — titled exactly "Bot Chat", the name that makes it
                    // canonical in the gateway's registry.
                    let handle = try await connection.createSession(
                        cwd: nil, profile: profile, title: BotChatPolicy.canonicalTitle)
                    guard generation == beginGeneration else { return }
                    effectiveProfile = profile
                    adopt(handle)
                    return
                }
                guard generation == beginGeneration else { return }
                try await performResume(
                    SessionSummary(
                        json: .object([
                            "session_id": .string(existing.resolvedID ?? existing.storedID),
                            "profile": .string(profile),
                        ]))!,
                    generation: generation)

            case .resume(let session):
                try await performResume(session, generation: generation)
            }
        } catch {
            guard generation == beginGeneration else { return }
            errorMessage = Self.describe(error)
        }
    }

    /// The open-time canonical registry lookup (`session.list` exact-title
    /// fast path). nil = confirmed absence; throws = unconfirmed (transport
    /// failure, or an empty answer contradicting the roster's last positive
    /// sighting — a profile backend mid-restart can answer an empty list).
    private func resolveCanonicalChat(
        profile: String, expectCanonical: Bool
    ) async throws -> BotSessionStub? {
        if let existing = try await connection.findCanonicalBotChat(profile: profile) {
            return existing
        }
        if expectCanonical {
            throw HermesError.malformedResponse(
                "Couldn't confirm this bot's Bot Chat registry — not starting a new chat. Try again.")
        }
        return nil
    }

    /// The resume body shared by `.resume` and the `.bot` registry path.
    /// Runs under the caller's begin generation.
    private func performResume(_ session: SessionSummary, generation: Int) async throws {
                let profile = session.profile ?? self.profile
                effectiveProfile = profile
                // Resume (omit_messages) and REST hydration run in parallel —
                // that is exactly why omit_messages exists. `order` must be
                // explicit: with a limit but no order the server anchors at
                // the OLDEST rows.
                async let hydration = Self.fetchPage(
                    connection, storedID: session.storedID, offset: 0, profile: profile)
                let handle = try await resumeWithRetry(
                    storedID: session.storedID, profile: profile)
                guard generation == beginGeneration else { return }
                adopt(handle)
                var page = await hydration
                guard generation == beginGeneration else { return }
                // Resume can re-anchor to a continuation session's durable
                // id (context-compression chains). A page fetched for the
                // requested id would splice the wrong session's history and
                // leave paging offsets pointing into it — refetch by the id
                // resume actually returned.
                if let reanchored = handle.storedID, reanchored != session.storedID {
                    page = await Self.fetchPage(
                        connection, storedID: reanchored, offset: 0, profile: profile)
                    guard generation == beginGeneration else { return }
                }
                switch page {
                case .success(let page):
                    store.hydrate(page.messages)
                    loadedOffset = page.messages.count
                    canLoadOlder = page.returned == (page.limit ?? Self.pageSize)
                    historyError = nil
                case .failure(let error):
                    // The session opened (resume succeeded) but persisted
                    // history didn't load: the chat would silently show
                    // only the live turn. Keep a visible retry path — and
                    // reset paging so a retry hydrates from the top.
                    loadedOffset = 0
                    canLoadOlder = false
                    historyError =
                        "Couldn't load this session's history: \(Self.describe(error))"
                }
                applyResumeExtras(handle.raw)
    }

    /// `session.resume` with a bounded retry on the two transient refusals
    /// v0.20.5 introduced around its orphan-reap: 4009 "disconnect interrupt
    /// settling" (the server is still winding down the turn our dropped
    /// socket triggered) and 4007 "session no longer live; retry resume".
    /// Both self-heal within a second or two. A genuinely missing session
    /// also 4007s — the retries cost ~3.6s there, then the error surfaces.
    private func resumeWithRetry(
        storedID: String, profile: String?
    ) async throws -> SessionHandle {
        var attempt = 0
        while true {
            do {
                return try await connection.resumeSession(
                    storedID: storedID, profile: profile)
            } catch let error as HermesError {
                guard case .rpcError(let code, _) = error,
                    code == HermesError.RPCCode.sessionBusy
                        || code == HermesError.RPCCode.sessionNotFound,
                    attempt < 3
                else { throw error }
                attempt += 1
                Self.logger.info(
                    "resume refused with \(code) — retry \(attempt)/3 after backoff")
                try? await Task.sleep(for: .milliseconds(600 * attempt))
            }
        }
    }

    /// One transcript page as a Result, so callers can surface the failure
    /// instead of `try?`-swallowing it (#16).
    private static func fetchPage(
        _ connection: HermesConnection, storedID: String, offset: Int, profile: String?
    ) async -> Result<TranscriptPage, Error> {
        do {
            return .success(
                try await connection.rest.sessionMessages(
                    storedID: storedID, limit: pageSize, offset: offset,
                    order: "latest", profile: profile))
        } catch {
            return .failure(error)
        }
    }

    /// Retry the failed history fetch: first page when hydration never
    /// succeeded, else the next older page.
    func retryHistory() async {
        historyError = nil
        if loadedOffset == 0 {
            guard let storedID, !isLoading else { return }
            let generation = beginGeneration
            isLoading = true
            defer { if generation == beginGeneration { isLoading = false } }
            let page = await Self.fetchPage(
                connection, storedID: storedID, offset: 0,
                profile: effectiveProfile ?? profile)
            guard generation == beginGeneration else { return }
            switch page {
            case .success(let page):
                store.hydrate(page.messages)
                loadedOffset = page.messages.count
                canLoadOlder = page.returned == (page.limit ?? Self.pageSize)
            case .failure(let error):
                historyError =
                    "Couldn't load this session's history: \(Self.describe(error))"
            }
        } else {
            await loadOlderMessages()
        }
    }

    private func adopt(_ handle: SessionHandle) {
        // The seq watermark is scoped to one runtime session: a new runtime
        // (create, or resume after a backend restart) numbers from 1 again,
        // and a kept high watermark would drop every event it emits.
        if handle.runtimeID != runtimeID { lastSeenSeq = nil }
        self.handle = handle
        runtimeID = handle.runtimeID
        storedID = handle.storedID ?? storedID
        if handle.desktopContract != nil {
            // session.info payloads flow through the store; seed the header
            // chips from the handle for the first paint.
            store.apply(
                GatewayEvent(
                    type: GatewayEvent.Kind.sessionInfo,
                    sessionID: handle.runtimeID,
                    payload: handle.raw["info"] ?? .null))
        }
    }

    /// `running`, `inflight`, and `auto_continue` from the resume result.
    /// Inflight restoration must run BEFORE the running flag: `setRunning(
    /// false)` seals any surviving live bubble, and sealing first would rob
    /// `restoreInflight` of the open bubble it reconciles against.
    private func applyResumeExtras(_ result: JSONValue) {
        if let inflight = result["inflight"], inflight.objectValue != nil {
            store.restoreInflight(
                user: inflight["user"]?.stringValue ?? "",
                corrections: inflight["corrections"]?.arrayValue?
                    .compactMap(\.stringValue) ?? [],
                assistant: inflight["assistant"]?.stringValue ?? "",
                streaming: inflight["streaming"]?.truthy ?? false,
                error: inflight["error"]?.stringValue)
        }
        // An accepted next-turn prompt waiting behind the running turn:
        // without this it is invisible after an app relaunch until it
        // finally drains.
        if let queued = result["queued"]?["user"]?.stringValue {
            store.restoreQueuedPrompt(queued)
        }
        store.setRunning(result["running"]?.truthy ?? false)
        // Blocking prompts raised while the socket was down are never
        // re-emitted as events — the resume payload's read-only snapshots
        // are their only carrier. Replay them through the normal event path
        // (after setRunning: an idle resume clears pendings). Their embedded
        // request_id answers via the usual respond methods.
        for (field, type) in [
            ("pending_approval", GatewayEvent.Kind.approvalRequest),
            ("pending_clarify", GatewayEvent.Kind.clarifyRequest),
        ] {
            if let snapshot = result[field], snapshot.objectValue != nil {
                store.apply(
                    GatewayEvent(type: type, sessionID: runtimeID, payload: snapshot))
            }
        }
    }

    /// The socket came back after a drop. Preferred path (v0.20.5+): re-bind
    /// via resume, then replay the exact missed events from the server's
    /// per-session ring (`session.events.since`) — the store continues from
    /// its pre-drop state with no re-hydration and no inflight-snapshot
    /// reconciliation. Fallback (older backend, gateway restart, ring
    /// overflow, recycled runtime id): the full resume + REST re-hydrate.
    func connectionBecameReady(isReconnect: Bool) async {
        guard isReconnect, let storedID else { return }
        if await replayAfterReconnect(storedID: storedID) { return }
        Self.logger.info("re-resuming \(storedID, privacy: .public) after reconnect")
        await begin(.resume(sessionSummaryForResume(storedID: storedID)))
    }

    /// Try the replay reconnect. Returns true when the store was brought
    /// current; false = caller must run the full resume path. Live events
    /// arriving during the RPCs are buffered and drained after the gap
    /// events, with seq dedupe collapsing any overlap.
    private func replayAfterReconnect(storedID: String) async -> Bool {
        // No watermark = backend never stamped seq, or the epoch changed
        // under us (gateway restart voids the ring's numbering).
        guard let watermark = lastSeenSeq, let previousRuntimeID = runtimeID else {
            return false
        }
        beginGeneration += 1
        let generation = beginGeneration
        isReplaying = true
        defer {
            if generation == beginGeneration {
                isReplaying = false
                replayBuffer.removeAll()
            }
        }
        do {
            let handle = try await resumeWithRetry(
                storedID: storedID, profile: effectiveProfile ?? profile)
            guard generation == beginGeneration else { return true }
            // A different runtime id means the old session runtime is gone
            // (backend restart / reclaim) — the replay ring with our seqs
            // died with it.
            guard handle.runtimeID == previousRuntimeID else { return false }
            adopt(handle)

            let page = try await connection.sessionEventsSince(
                sessionID: previousRuntimeID, lastSeen: watermark)
            guard generation == beginGeneration else { return true }
            if page.truncated {
                Self.logger.info("replay ring truncated past seq \(watermark) — full resume")
                return false
            }
            if let epoch = page.epoch, let known = replayEpoch, epoch != known {
                return false
            }
            for event in page.events { applyDeduped(event) }
            // An empty replay can't carry the running transition; take the
            // resume result's word for it then — BEFORE draining live events
            // that arrived during the fetch, which postdate the resume
            // snapshot. (A non-empty replay carries its own session.info
            // frames — the resume flag predates them, so it is skipped.)
            if page.events.isEmpty {
                applyResumeExtras(handle.raw)
            }
            drainReplayBuffer()
            Self.logger.info(
                "replayed \(page.events.count) events after reconnect (seq \(watermark) → \(self.lastSeenSeq ?? watermark))"
            )
            return true
        } catch {
            guard generation == beginGeneration else { return true }
            // -32601 (pre-0.20.5), transport errors, resume failures: the
            // full path retries resume itself and surfaces real errors.
            Self.logger.info(
                "replay reconnect unavailable (\(Self.describe(error), privacy: .public)) — full resume"
            )
            return false
        }
    }

    /// Apply one event with seq dedupe: a frame at or below the watermark
    /// was already applied (live before the drop, or via an earlier replay).
    /// Everything that passes flows through the normal hold/batching
    /// pipeline — replayed events are ordinary events that arrived late.
    private func applyDeduped(_ event: GatewayEvent) {
        if let seq = event.seq {
            guard seq > (lastSeenSeq ?? 0) else { return }
            lastSeenSeq = seq
        }
        if transcriptHoldActive {
            if event.type == GatewayEvent.Kind.sessionInfo {
                // The turn-end carrier (`running: false` seals the open
                // bubble): everything buffered must land BEFORE the seal or
                // drained text would open a stray bubble below it.
                drainHeldEvents()
            } else if !Self.holdExemptTypes.contains(event.type) {
                heldEvents.append(event)
                return
            }
        }
        applyLive(event)
    }

    private func drainReplayBuffer() {
        let buffered = replayBuffer
        replayBuffer.removeAll()
        for event in buffered { applyDeduped(event) }
    }

    private func sessionSummaryForResume(storedID: String) -> SessionSummary {
        SessionSummary(
            json: .object([
                "session_id": .string(storedID),
                "profile": profile.map { .string($0) } ?? .null,
            ]))!
    }

    /// Politely close the runtime session when the view goes away.
    func teardown() async {
        guard let runtimeID else { return }
        await connection.closeSession(sessionID: runtimeID)
    }

    // MARK: Events

    /// Route one gateway event; events for other sessions are ignored.
    ///
    /// Streaming text deltas are BATCHED (~12Hz) instead of applied per
    /// event: every store mutation runs a full SwiftUI transaction, and while
    /// the viewport sits over the LazyVStack's *estimated* (un-materialized)
    /// region — reader scrolled up, reply growing below — each transaction
    /// re-runs the lazy item-phase pass for the whole transcript. At the
    /// per-token WS cadence those passes arrive faster than the device can
    /// retire them and the main thread livelocks for the entire turn (the
    /// "window freezes when I send while scrolled up" report; 84s Severe
    /// Hang, 100% Running inside LazyLayoutViewCache.updateItemPhases, traced
    /// on an iPhone 17 Pro Max). Structural events still apply immediately,
    /// flushing buffered text first so ordering is preserved.
    func handle(event: GatewayEvent) {
        // Replay-epoch bookkeeping rides on gateway.ready: a changed epoch
        // means the gateway restarted — its seq counters reset to 1, so a
        // kept watermark would silently drop every future event.
        if event.type == GatewayEvent.Kind.gatewayReady {
            let epoch = event.payload["replay_epoch"]?.stringValue
            if replayEpoch != nil, epoch != replayEpoch { lastSeenSeq = nil }
            replayEpoch = epoch
        }
        guard let runtimeID else { return }
        guard event.sessionID == nil || event.sessionID == runtimeID else { return }
        if isReplaying, event.seq != nil {
            // A replay fetch is in flight: gap events must land first. This
            // live frame drains right after them (seq dedupe drops it if the
            // replay page already carried it).
            replayBuffer.append(event)
            return
        }
        applyDeduped(event)
    }

    /// The reader is away from the bottom while a reply streams: STOP
    /// mutating the transcript. Every store mutation runs a LazyVStack
    /// item-phase pass over the whole transcript, and with the viewport over
    /// the lazy container's estimated span one pass costs more than a frame —
    /// even the 80ms-batched cadence saturated the main thread the moment
    /// the user scrolled around mid-stream (traced: 95s Severe Hang inside
    /// LazyLayoutViewCache.updateItemPhases). None of the held content is
    /// visible anyway; it replays in order when the reader returns to the
    /// bottom or the turn ends. Blocking prompts, usage, and title events
    /// stay live — they render outside the transcript.
    func setTranscriptHold(_ hold: Bool) {
        guard hold != transcriptHoldActive else { return }
        transcriptHoldActive = hold
        if !hold { drainHeldEvents() }
    }

    private(set) var transcriptHoldActive = false
    private var heldEvents: [GatewayEvent] = []

    /// Events that never touch transcript items (pending-prompt fields and
    /// header chrome only) — safe and necessary to apply while holding.
    private static let holdExemptTypes: Set<String> = [
        GatewayEvent.Kind.sessionUsage,
        GatewayEvent.Kind.sessionTitle,
        GatewayEvent.Kind.sessionsChanged,
        GatewayEvent.Kind.statusUpdate,
        GatewayEvent.Kind.notificationClear,
        GatewayEvent.Kind.approvalRequest,
        GatewayEvent.Kind.clarifyRequest,
        GatewayEvent.Kind.clarifyExpire,
        GatewayEvent.Kind.sudoRequest,
        GatewayEvent.Kind.sudoExpire,
        GatewayEvent.Kind.secretRequest,
        GatewayEvent.Kind.secretExpire,
        GatewayEvent.Kind.mcpSetupRequest,
        GatewayEvent.Kind.mcpSetupExpire,
    ]

    private func drainHeldEvents() {
        if !heldEvents.isEmpty {
            let events = heldEvents
            heldEvents = []
            for event in events { applyLive(event) }
        }
        flushPendingDeltas()
    }

    private func applyLive(_ event: GatewayEvent) {
        switch event.type {
        case GatewayEvent.Kind.messageDelta:
            pendingMessageText += event.payload["text"]?.stringValue ?? ""
            scheduleDeltaFlush()
            return
        case GatewayEvent.Kind.reasoningDelta, GatewayEvent.Kind.thinkingDelta:
            pendingReasoningText += event.payload["text"]?.stringValue ?? ""
            scheduleDeltaFlush()
            return
        default:
            flushPendingDeltas()
            store.apply(event)
        }
        // A session.title event may also rename; keep the stored id fresh
        // if the server re-anchors it.
        if event.type == GatewayEvent.Kind.sessionInfo,
            let stored = event.payload["stored_session_id"]?.stringValue, !stored.isEmpty
        {
            storedID = stored
        }
    }

    private var pendingMessageText = ""
    private var pendingReasoningText = ""
    private var deltaFlushScheduled = false

    private func scheduleDeltaFlush() {
        guard !deltaFlushScheduled else { return }
        deltaFlushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            deltaFlushScheduled = false
            flushPendingDeltas()
        }
    }

    private func flushPendingDeltas() {
        if !pendingReasoningText.isEmpty {
            store.apply(
                GatewayEvent(
                    type: GatewayEvent.Kind.reasoningDelta, sessionID: runtimeID,
                    payload: .object(["text": .string(pendingReasoningText)])))
            pendingReasoningText = ""
        }
        if !pendingMessageText.isEmpty {
            store.apply(
                GatewayEvent(
                    type: GatewayEvent.Kind.messageDelta, sessionID: runtimeID,
                    payload: .object(["text": .string(pendingMessageText)])))
            pendingMessageText = ""
        }
    }

    // MARK: Actions

    func submit(_ text: String, attachments: [PendingAttachment] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // /new, /reset, /compact in a canonical Bot Chat run REAL compression
        // via session.compress — prompt.submit treats slash text as an
        // ordinary message, so submitting "/compact" would only send those
        // characters to the model while claiming a fresh context.
        if isCanonicalBotChat, attachments.isEmpty, BotChatPolicy.isCompactCommand(trimmed) {
            await runCanonicalCompact()
            return
        }
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        let echoed = attachments.map(Self.echoAttachment(for:))
        let echoID = store.appendUserMessage(trimmed, attachments: echoed, state: .sending)
        if !attachments.isEmpty { pendingUploads[echoID] = attachments }
        await dispatch(text: trimmed, echoID: echoID)
    }

    /// The transcript row a composed attachment echoes as. Only images carry
    /// preview bytes: `previewData != nil` is what routes a row down the
    /// thumbnail branch, so a PDF's or file's raw bytes there would draw a
    /// broken image instead of the filename chip. Non-images render as chips
    /// on the live path, matching hydrated rows — which never carry
    /// attachment bytes at all, because the backend doesn't round-trip them.
    nonisolated static func echoAttachment(for attachment: PendingAttachment)
        -> MessageAttachment
    {
        MessageAttachment(
            id: attachment.id, kind: attachment.kind, filename: attachment.filename,
            previewData: attachment.kind == .image
                ? (attachment.thumbnail ?? attachment.data) : nil)
    }

    /// Re-send a failed echo, keeping its identity (the retry updates the
    /// same bubble rather than appending a twin). Its attachments stay in
    /// `pendingUploads` until a send succeeds, so the retry re-stages them.
    func retrySend(messageID: String) async {
        guard case .user(let message)? = store.items.first(where: { $0.id == messageID }),
            message.sendState == .failed
        else { return }
        store.setUserMessageState(id: messageID, .sending)
        await dispatch(text: message.text, echoID: messageID)
    }

    private func dispatch(text: String, echoID: String) async {
        let previous = sendQueue
        let task = Task { [previous] in
            await previous?.value
            await self.performDispatch(text: text, echoID: echoID)
        }
        sendQueue = task
        await task.value
    }

    private func performDispatch(text: String, echoID: String) async {
        guard let runtimeID else {
            store.setUserMessageState(id: echoID, .failed)
            return
        }
        let attachments = pendingUploads[echoID] ?? []
        do {
            // Submitting while busy doesn't error: the server queues,
            // redirects, or steers per its busy-input policy and says which
            // in the result — surface that, or "/steer worked but nothing
            // acknowledged it" (#6). Attachments are staged first and consumed
            // by the submit, with two cleanup modes: images and PDF pages are
            // detached on failure (an orphaned staged image is silently
            // swallowed by the NEXT prompt), while staged files are inert —
            // nothing reads them until a prompt names them, so a failed send
            // simply leaves them unreferenced. Retrying a file send re-stages
            // it and the earlier orphan stays on the gateway disk as
            // `name-2.ext`; that residual is accepted.
            let status = try await AttachmentUpload.dispatch(
                text: text,
                attachments: attachments,
                // @Sendable: the sequencer is nonisolated, so these closures
                // leave the MainActor — they touch nothing but the connection
                // actor and the values captured here.
                attach: { @Sendable [connection] attachment in
                    switch attachment.kind {
                    case .image:
                        let result = try await connection.attachImageBytes(
                            sessionID: runtimeID,
                            base64: attachment.data.base64EncodedString(),
                            filename: attachment.filename)
                        return StagedAttachment(detachPaths: [result.path], refText: nil)
                    case .pdf:
                        do {
                            let result = try await connection.attachPDF(
                                sessionID: runtimeID,
                                base64: attachment.data.base64EncodedString(),
                                filename: attachment.filename)
                            return StagedAttachment(detachPaths: result.pagePaths, refText: nil)
                        } catch let HermesError.rpcError(code, _)
                            where code == 5028 || code == -32601
                        {
                            // No poppler on the gateway (or a pre-pdf.attach backend):
                            // degrade to a workspace file the agent reads with its tools.
                            let result = try await connection.attachFile(
                                sessionID: runtimeID,
                                dataURL: FileAttachmentWire.dataURL(
                                    attachment.data, filename: attachment.filename),
                                name: attachment.filename)
                            return StagedAttachment(detachPaths: [], refText: result.refText)
                        }
                    case .file:
                        let result = try await connection.attachFile(
                            sessionID: runtimeID,
                            dataURL: FileAttachmentWire.dataURL(
                                attachment.data, filename: attachment.filename),
                            name: attachment.filename)
                        return StagedAttachment(detachPaths: [], refText: result.refText)
                    }
                },
                // Cleanup must outlive cancellation: a cancelled send still
                // has to unstage what it staged, and an inherited-cancellation
                // detach would no-op and leak the image into the next prompt.
                // The shield is an unstructured `Task` (NOT detached): it
                // doesn't inherit the caller's cancellation, so a cancelled
                // send still completes the detach. Detached isn't needed for
                // that and would only leave the actor context. Awaiting its
                // value keeps the sequencer's ordering.
                detach: { @Sendable [connection] path in
                    await Task {
                        try? await connection.detachImage(sessionID: runtimeID, path: path)
                    }.value
                },
                submit: { @Sendable [connection] text in
                    try await connection.submitPrompt(sessionID: runtimeID, text: text)
                })
            pendingUploads.removeValue(forKey: echoID)
            // The DB row exists after the first prompt; a created session
            // learns its stored id via session.info events.
            store.setUserMessageState(id: echoID, status == "queued" ? .queued : .sent)
            switch status {
            case "redirected":
                store.appendNotice("Redirecting the current turn to your message…")
            case "steered":
                store.appendNotice(
                    "Steering — the agent will see your message after its current action.")
            default:
                break  // streaming/queued are visible on the bubble itself.
            }
        } catch {
            // The exact echo is marked, not removed: the user's text is
            // preserved for a one-tap retry (#17).
            store.setUserMessageState(id: echoID, .failed)
            errorMessage = Self.describe(error)
        }
    }

    /// A Bot Chat never forks: compress the working context in place and
    /// re-resume, so the same conversation continues with fresh headroom.
    /// Compression can rotate the lineage tip — the re-resume's re-anchor
    /// logic follows it.
    private func runCanonicalCompact() async {
        guard let runtimeID, let storedID else {
            errorMessage = "The session isn't open yet — try again in a moment."
            return
        }
        store.appendNotice(
            "A Bot Chat never forks — compressing the working context in place…")
        do {
            let status = try await connection.compressSession(sessionID: runtimeID)
            switch status {
            case "compressed":
                await begin(.resume(sessionSummaryForResume(storedID: storedID)))
            case "pending":
                store.appendNotice(
                    "Compression is still running server-side — the transcript refreshes when it lands."
                )
            default:
                store.appendNotice("Compression ended early (\(status)).", level: .error)
            }
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func interrupt() async {
        guard let runtimeID else { return }
        try? await connection.interruptSession(sessionID: runtimeID)
    }

    func loadOlderMessages() async {
        guard canLoadOlder || historyError != nil, let storedID, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let result = await Self.fetchPage(
            connection, storedID: storedID, offset: loadedOffset,
            profile: effectiveProfile ?? profile)
        switch result {
        case .success(let page):
            store.prependOlder(page.messages)
            loadedOffset += page.messages.count
            canLoadOlder =
                !page.messages.isEmpty && page.returned == (page.limit ?? Self.pageSize)
            historyError = nil
        case .failure(let error):
            // Keep the retry path visible even though canLoadOlder stays
            // true — a silent failure here permanently hid older history.
            historyError = "Couldn't load earlier messages: \(Self.describe(error))"
        }
    }

    func rename(_ title: String) async {
        // The canonical title IS the bot relationship: the gateway's registry
        // resolves by the exact name "Bot Chat", so renaming it severs the
        // forever-chat and the next open would mint a replacement. The UI
        // hides Rename for canonical chats; this guard covers every other
        // path to the title write.
        guard !isCanonicalBotChat else {
            store.appendNotice(
                "This is the bot's canonical Bot Chat — its title is its identity and can't change.",
                level: .error)
            return
        }
        guard let runtimeID else { return }
        _ = try? await connection.setSessionTitle(sessionID: runtimeID, title: title)
    }

    // MARK: Blocking-prompt responses

    // The agent thread stays frozen until an answer actually reaches the
    // server, so the pending prompt is cleared only after the RPC succeeds —
    // on failure it stays up for a retry and the error is surfaced. Clearing
    // is identity-guarded: the RPC suspends this actor, and a NEWER request
    // arriving mid-flight must not be wiped by the older response.
    //
    // Transport success is NOT delivery: a late answer resolves with
    // `status: "expired"` and the agent never sees it. The stale card is
    // closed either way, but an expired answer surfaces a transcript notice
    // instead of silently pretending the password/credential landed.

    /// What actually happened to an answered blocking prompt.
    enum PromptDeliveryOutcome {
        /// The agent received the answer.
        case delivered
        /// The request expired server-side first — the answer was discarded.
        case expired
        /// The RPC failed; the prompt stays up for a retry.
        case failed
    }

    @discardableResult
    func respondApproval(_ request: ApprovalRequest, choice: String) async -> Bool {
        guard let runtimeID else { return false }
        do {
            // The server queues approvals and resolves the OLDEST without a
            // request_id — target the exact card the user answered.
            try await connection.respondApproval(
                sessionID: runtimeID, choice: choice, requestID: request.requestID)
            store.clearApproval(matching: request)
            return true
        } catch {
            errorMessage = Self.describe(error)
            return false
        }
    }

    /// Decline an MCP setup card. Mercury has no in-app MCP install/OAuth
    /// flow yet, so decline is the only actionable answer — it unblocks the
    /// agent immediately (which otherwise waits out a 10-minute timeout) and
    /// tells it to continue without the server.
    func declineMcpSetup(_ request: McpSetupRequest) async -> PromptDeliveryOutcome {
        do {
            let status = try await connection.respondMcpSetup(
                requestID: request.requestID, status: "declined", server: request.server,
                detail: "Declined from Mercury (in-app MCP setup is not supported).")
            return settlePrompt(
                status, what: "answer",
                clear: { self.store.clearMcpSetup(requestID: request.requestID) })
        } catch {
            errorMessage = Self.describe(error)
            return .failed
        }
    }

    func respondClarify(requestID: String, answer: String) async -> PromptDeliveryOutcome {
        do {
            let status = try await connection.respondClarify(
                requestID: requestID, answer: answer)
            return settlePrompt(
                status, what: "answer",
                clear: { self.store.clearClarify(requestID: requestID) })
        } catch {
            errorMessage = Self.describe(error)
            return .failed
        }
    }

    /// One answered question of a BATCH clarify. The batch resolves when the
    /// last question locks; until then answers stay editable server-side.
    enum BatchClarifyOutcome {
        /// Locked; these qids are still waiting.
        case progress(remaining: [String])
        /// That was the last one — the batch resolved and the card cleared.
        case completed
        case expired
        case failed
    }

    func respondClarifyQuestion(
        requestID: String, questionID: String, answer: String
    ) async -> BatchClarifyOutcome {
        do {
            guard
                let remaining = try await connection.respondClarifyQuestion(
                    requestID: requestID, questionID: questionID, answer: answer)
            else {
                _ = settlePrompt(
                    .expired, what: "answer",
                    clear: { self.store.clearClarify(requestID: requestID) })
                return .expired
            }
            if remaining.isEmpty {
                store.clearClarify(requestID: requestID)
                return .completed
            }
            return .progress(remaining: remaining)
        } catch {
            errorMessage = Self.describe(error)
            return .failed
        }
    }

    func respondSudo(requestID: String, password: String) async -> PromptDeliveryOutcome {
        do {
            let status = try await connection.respondSudo(
                requestID: requestID, password: password)
            return settlePrompt(
                status, what: "password",
                clear: { self.store.clearSudo(requestID: requestID) })
        } catch {
            errorMessage = Self.describe(error)
            return .failed
        }
    }

    func respondSecret(requestID: String, value: String) async -> PromptDeliveryOutcome {
        do {
            let status = try await connection.respondSecret(requestID: requestID, value: value)
            return settlePrompt(
                status, what: "credential",
                clear: { self.store.clearSecret(requestID: requestID) })
        } catch {
            errorMessage = Self.describe(error)
            return .failed
        }
    }

    private func settlePrompt(
        _ status: PromptResponseStatus, what: String, clear: () -> Void
    ) -> PromptDeliveryOutcome {
        clear()
        switch status {
        case .accepted:
            return .delivered
        case .expired:
            store.appendNotice(
                "The request expired before your \(what) was delivered — the agent never received it.",
                level: .error)
            return .expired
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? HermesError)?.errorDescription ?? error.localizedDescription
    }
}
