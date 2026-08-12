import Foundation
import MercuryKit
import Observation

/// Reduces one session's gateway event stream (plus REST hydration) into an
/// ordered list of renderable transcript items.
///
/// Feed events **in arrival order** (the server's batch coalescing makes
/// arrival order trustworthy; a non-streaming frame always flushes ahead of
/// the batch). `@MainActor` serializes application with UI reads.
///
/// Merge rule: hydrate first, then apply live events. Hydrated rows carry
/// durable row ids; live items don't until re-hydration, so `hydrate`
/// replaces the hydrated prefix while live items appended after the last
/// hydration are preserved.
@MainActor
@Observable
public final class TranscriptStore {
    // MARK: Rendered state

    public private(set) var items: [TranscriptItem] = []

    /// True while a turn is streaming. Driven by `session.info.running` —
    /// the REAL end-of-turn signal (`message.complete` can be followed by
    /// chained turns).
    public private(set) var running = false

    /// `tool.generating {name}` — transient "preparing…" hint. No tool row
    /// exists yet (that happens at `tool.start`).
    public private(set) var generatingToolName: String?

    /// Blocking prompts. The agent thread is frozen until these are
    /// answered — surface immediately.
    public private(set) var pendingApproval: ApprovalRequest?
    public private(set) var pendingClarify: ClarifyRequest?
    public private(set) var pendingSudo: SudoRequest?
    public private(set) var pendingSecret: SecretRequest?

    /// Session metadata from `session.info` / `session.title`.
    public private(set) var title: String?
    public private(set) var model: String?
    public private(set) var profileName: String?
    /// Durable id observed in `session.info.stored_session_id` (re-anchor).
    public private(set) var storedSessionID: String?

    /// Cumulative usage across completed turns this connection.
    public private(set) var totalUsage = UsageTotals()

    /// Latest turn error (`message.complete` with `status: "error"`).
    public private(set) var lastError: String?

    public struct UsageTotals: Sendable, Equatable {
        public var calls = 0
        public var inputTokens = 0
        public var outputTokens = 0
        public var totalTokens = 0

        mutating func add(_ usage: TurnUsage) {
            calls += usage.calls
            inputTokens += usage.inputTokens
            outputTokens += usage.outputTokens
            totalTokens += usage.totalTokens
        }
    }

    // MARK: Internal reducer state

    /// Index into `items` of the currently-open (streaming) assistant
    /// bubble, when one exists.
    private var openBubbleIndex: Int?
    /// tool_id → index into `items` for running tool rows.
    private var toolRowIndex: [String: Int] = [:]
    /// subagent_id → index into `items` for flattened subagent rows.
    private var subagentRowIndex: [String: Int] = [:]
    /// Monotonic source for live item ids.
    private var liveCounter = 0
    /// Count of items that came from hydration (prefix of `items`).
    private var hydratedCount = 0
    /// Durable row ids currently present (hydration dedupe).
    private var knownRowIDs: Set<Int> = []

    public init() {}

    private func nextLiveID(_ kind: String) -> String {
        liveCounter += 1
        return "live-\(kind)-\(liveCounter)"
    }

    // MARK: Hydration

    /// Replace the hydrated prefix with `messages` (oldest-first), keeping
    /// any live items that streamed in after the last hydration. Call with
    /// the REST transcript page(s) for this session's **stored** id.
    public func hydrate(_ messages: [TranscriptMessage]) {
        let liveSuffix = Array(items.dropFirst(hydratedCount))
        var hydrated: [TranscriptItem] = []
        knownRowIDs.removeAll(keepingCapacity: true)

        for message in messages {
            guard let item = Self.item(from: message) else { continue }
            if let rowID = message.rowID { knownRowIDs.insert(rowID) }
            hydrated.append(item)
        }

        // Drop live items whose rows are now persisted (best-effort: live
        // items have no row id, so match user messages by text and sealed
        // assistant bubbles by text).
        let hydratedTexts = Set(hydrated.compactMap { item -> String? in
            switch item {
            case .user(let m): return "u:" + m.text
            case .assistant(let m): return "a:" + m.text
            default: return nil
            }
        })
        // A turn that completed while the socket was down is persisted by
        // the time this page arrives: the newest hydrated reply extending a
        // live streaming bubble supersedes it. (A still-live turn isn't
        // persisted yet, so its bubble survives — or, if dropped because the
        // previous reply happens to extend it, `restoreInflight` rebuilds it
        // from the resume snapshot right after.)
        let latestHydratedReply = hydrated.reversed()
            .compactMap { item -> String? in
                if case .assistant(let m) = item { return m.text }
                return nil
            }
            .first
        // Tool identity for reconciliation: a live running row whose call is
        // now persisted (typically completed while the socket was down) is
        // superseded by the hydrated row — keeping both leaves a duplicate
        // that spins forever.
        let hydratedToolIDs = Set(
            hydrated.compactMap { item -> String? in
                if case .tool(let t) = item { return t.toolID }
                return nil
            })
        let survivors = liveSuffix.filter { item in
            switch item {
            case .user(let m):
                return !hydratedTexts.contains("u:" + m.text)
            case .assistant(let m) where m.isStreaming:
                if let final = latestHydratedReply, final.hasPrefix(m.text) {
                    return false
                }
                // A mid-turn redirect/interim commit can persist the partial
                // as its own row: the live bubble then equals a persisted
                // SEGMENT rather than a prefix of the latest reply, and
                // surviving would duplicate it under the final response.
                if hydratedTexts.contains("a:" + m.text) {
                    return false
                }
                return true
            case .assistant(let m):
                return m.error != nil || !hydratedTexts.contains("a:" + m.text)
            case .tool(let t):
                if let toolID = t.toolID, hydratedToolIDs.contains(toolID) {
                    return false  // Persisted (completed) row wins.
                }
                return t.isRunning
            case .notice:
                return true
            }
        }

        items = hydrated + survivors
        hydratedCount = hydrated.count
        reindexAfterMutation()
    }

    /// Prepend an older transcript page (scrollback paging).
    public func prependOlder(_ messages: [TranscriptMessage]) {
        var older: [TranscriptItem] = []
        for message in messages {
            if let rowID = message.rowID {
                guard !knownRowIDs.contains(rowID) else { continue }
                knownRowIDs.insert(rowID)
            }
            if let item = Self.item(from: message) { older.append(item) }
        }
        items.insert(contentsOf: older, at: 0)
        hydratedCount += older.count
        reindexAfterMutation()
    }

    private static func item(from message: TranscriptMessage) -> TranscriptItem? {
        if message.displayKind == "hidden" { return nil }
        switch message.role {
        case "user":
            guard !message.text.isEmpty else { return nil }
            return .user(
                UserMessage(
                    id: message.id, text: message.text,
                    rowID: message.rowID, timestamp: message.timestamp))
        case "assistant":
            guard !message.text.isEmpty || !(message.reasoning ?? "").isEmpty else {
                return nil
            }
            return .assistant(
                AssistantMessage(
                    id: message.id,
                    text: message.text,
                    reasoning: message.reasoning ?? "",
                    rowID: message.rowID,
                    timestamp: message.timestamp))
        case "tool":
            return .tool(
                ToolActivity(
                    id: message.id,
                    toolID: message.toolCallID,
                    name: message.toolName ?? "tool",
                    context: message.context,
                    resultText: message.text.isEmpty ? nil : message.text,
                    rowID: message.rowID,
                    timestamp: message.timestamp))
        default:
            return nil  // system rows aren't rendered
        }
    }

    /// Rebuild open-bubble / tool-row indices after items were reordered.
    private func reindexAfterMutation() {
        openBubbleIndex = nil
        toolRowIndex.removeAll(keepingCapacity: true)
        subagentRowIndex.removeAll(keepingCapacity: true)
        for (index, item) in items.enumerated() {
            switch item {
            case .assistant(let m) where m.isStreaming:
                openBubbleIndex = index
            case .tool(let t):
                if let toolID = t.toolID, t.isRunning { toolRowIndex[toolID] = index }
                // Reducer identity, NOT the display label: labels like
                // "Subagent 1/2" collide across turns, and a completion for
                // `sa1` looked up by label would miss its row after a
                // hydration/prepend reindex.
                if let subagentID = t.subagentID, t.isRunning {
                    subagentRowIndex[subagentID] = index
                }
            default:
                break
            }
        }
    }

    // MARK: Resume restoration

    /// Rebuild the turn that was streaming when the socket dropped, from
    /// `session.resume`'s `inflight` payload. Call after hydration: the
    /// inflight turn is exactly the part not yet persisted.
    ///
    /// A reconnect re-runs resume while the interrupted turn may still be on
    /// screen (the local echo and streaming bubble survive `hydrate`), so
    /// this reconciles against what's already rendered instead of appending
    /// a second copy of the turn.
    public func restoreInflight(
        user: String, corrections: [String] = [], assistant: String,
        streaming: Bool, error: String? = nil
    ) {
        var turnStart = items.count
        if !user.isEmpty {
            if let existing = items.lastIndex(where: { item in
                if case .user(let m) = item { return m.text == user }
                return false
            }) {
                turnStart = existing
            } else {
                appendUserMessage(user)
                turnStart = items.count - 1
            }
        }
        var seenUserTexts = Set(
            items[turnStart...].compactMap { item -> String? in
                if case .user(let m) = item { return m.text }
                return nil
            })
        for correction in corrections where !correction.isEmpty {
            if seenUserTexts.insert(correction).inserted {
                appendUserMessage(correction)
            }
        }

        guard !assistant.isEmpty || streaming || error != nil else { return }
        if let error { lastError = error }

        if let index = openBubbleIndex, case .assistant(var bubble) = items[index] {
            // The streaming bubble survived hydration — this is the same
            // turn. The snapshot is the whole turn's text and is the ONLY
            // carrier of anything emitted while the socket was down (missed
            // deltas are never replayed): when it extends what's already
            // rendered across this turn's bubbles, append the missing
            // suffix. When it can't be lined up with the streamed segments
            // (mid-turn deltas were lost too), keep the streamed text rather
            // than duplicate bubbles sealed at tool boundaries.
            if !assistant.isEmpty {
                let renderedStart = min(turnStart, index)
                let rendered = items[renderedStart...]
                    .compactMap { item -> String? in
                        if case .assistant(let m) = item { return m.text }
                        return nil
                    }
                    .joined()
                if assistant.hasPrefix(rendered) {
                    bubble.text += assistant.dropFirst(rendered.count)
                } else if bubble.text.isEmpty {
                    bubble.text = assistant
                }
            }
            bubble.isStreaming = streaming && error == nil
            bubble.error = error
            items[index] = .assistant(bubble)
            openBubbleIndex = bubble.isStreaming ? index : nil
            return
        }
        if !assistant.isEmpty, case .assistant(var last) = items.last,
            last.text == assistant
        {
            // A sealed copy of this reply is already the last item — realign
            // its state with the snapshot instead of appending a twin: a
            // still-streaming snapshot reopens it so later deltas land here,
            // and an error attaches to it.
            last.isStreaming = streaming && error == nil
            last.error = error ?? last.error
            items[items.count - 1] = .assistant(last)
            openBubbleIndex = last.isStreaming ? items.count - 1 : nil
            return
        }

        // No open bubble and the last item isn't the reply (a tool row or a
        // correction echo is last, or hydration replaced the live bubble with
        // persisted mid-turn rows). The snapshot is still the WHOLE turn's
        // text: reconcile it against everything rendered in this turn before
        // appending, or the already-shown prefix duplicates below the tool
        // row / correction (#9, #5).
        let scanStart: Int
        if !user.isEmpty {
            scanStart = turnStart
        } else if let lastUser = items.lastIndex(where: { item in
            if case .user = item { return true }
            return false
        }) {
            scanStart = lastUser + 1
        } else {
            scanStart = 0
        }
        let rendered = items[min(scanStart, items.count)...]
            .compactMap { item -> String? in
                if case .assistant(let m) = item { return m.text }
                return nil
            }
            .joined()
        if !assistant.isEmpty, !rendered.isEmpty {
            if assistant == rendered { return }  // Fully rendered already.
            if assistant.hasPrefix(rendered) {
                // Only the tail past the rendered total is new — it was
                // emitted after the boundary that sealed the last segment,
                // so it belongs in a fresh bubble at the end.
                var bubble = AssistantMessage(
                    id: nextLiveID("assistant"),
                    text: String(assistant.dropFirst(rendered.count)),
                    timestamp: Date())
                bubble.isStreaming = streaming && error == nil
                bubble.error = error
                items.append(.assistant(bubble))
                openBubbleIndex = bubble.isStreaming ? items.count - 1 : nil
                return
            }
            // Unalignable (mid-turn deltas were lost too): keep the rendered
            // segments rather than appending a twin of the whole snapshot.
            return
        }

        var bubble = AssistantMessage(
            id: nextLiveID("assistant"), text: assistant, timestamp: Date())
        bubble.isStreaming = streaming && error == nil
        bubble.error = error
        items.append(.assistant(bubble))
        openBubbleIndex = bubble.isStreaming ? items.count - 1 : nil
    }

    /// Seed the busy flag from a resume result (`running`), ahead of any
    /// `session.info` event. `false` performs the same end-of-turn cleanup
    /// as `session.info` — a turn that completed while the socket was down
    /// arrives with no inflight payload, and any surviving live bubble would
    /// otherwise stay marked as streaming forever.
    public func setRunning(_ flag: Bool) {
        running = flag
        if !flag { finishTurn() }
    }

    /// End-of-turn cleanup shared by `session.info {running: false}` and a
    /// resume result reporting the session idle.
    private func finishTurn() {
        if let index = openBubbleIndex, case .assistant(var bubble) = items[index] {
            bubble.isStreaming = false
            items[index] = .assistant(bubble)
            openBubbleIndex = nil
        }
        // No tool or subagent outlives its turn: a row whose completion
        // event was lost (dropped socket, hydration replacing its twin)
        // must not spin forever once the session reports idle.
        for (index, item) in items.enumerated() {
            if case .tool(var row) = item, row.isRunning {
                row.isRunning = false
                items[index] = .tool(row)
            }
        }
        toolRowIndex.removeAll(keepingCapacity: true)
        subagentRowIndex.removeAll(keepingCapacity: true)
        generatingToolName = nil
        // Blocking prompts can't outlive the turn.
        pendingApproval = nil
        pendingClarify = nil
        pendingSudo = nil
        pendingSecret = nil
    }

    // MARK: Local echo

    /// Append the user's message optimistically at submit time.
    public func appendUserMessage(_ text: String) {
        items.append(.user(UserMessage(id: nextLiveID("user"), text: text, timestamp: Date())))
        lastError = nil
    }

    /// Visible one-liner in the transcript (blocking-prompt expiry and other
    /// client-side conditions the user must not miss).
    public func appendNotice(_ text: String, level: SystemNotice.Level = .info) {
        items.append(.notice(SystemNotice(id: nextLiveID("notice"), text: text, level: level)))
    }

    // MARK: Event reduction

    public func apply(_ event: GatewayEvent) {
        switch event.type {
        case GatewayEvent.Kind.messageStart:
            openBubble()

        case GatewayEvent.Kind.messageDelta:
            appendToBubble(text: event.payload["text"]?.stringValue ?? "")

        case GatewayEvent.Kind.reasoningDelta, GatewayEvent.Kind.thinkingDelta:
            appendToBubble(reasoning: event.payload["text"]?.stringValue ?? "")

        case GatewayEvent.Kind.messageInterim:
            sealInterim(event.payload)

        case GatewayEvent.Kind.messageComplete:
            completeTurnMessage(event.payload)

        case GatewayEvent.Kind.toolGenerating:
            generatingToolName = event.payload["name"]?.stringValue ?? "tool"

        case GatewayEvent.Kind.toolStart:
            generatingToolName = nil
            // Tool rows are their own transcript items: seal any open bubble
            // so text streamed after the tool opens a NEW bubble below the
            // row — matching desktop's interleaved ordering. (Empty sealed
            // bubbles simply render as nothing.)
            sealOpenBubble()
            startTool(event.payload)

        case GatewayEvent.Kind.toolProgress:
            progressTool(event.payload)

        case GatewayEvent.Kind.toolComplete:
            generatingToolName = nil
            completeTool(event.payload)

        case GatewayEvent.Kind.sessionInfo:
            applySessionInfo(event.payload)

        case GatewayEvent.Kind.sessionTitle:
            if let newTitle = event.payload["title"]?.stringValue, !newTitle.isEmpty {
                title = newTitle
            }

        case GatewayEvent.Kind.approvalRequest:
            pendingApproval = ApprovalRequest(event: event)

        case GatewayEvent.Kind.clarifyRequest:
            pendingClarify = ClarifyRequest(event: event)

        case GatewayEvent.Kind.clarifyExpire:
            if pendingClarify?.requestID == event.payload["request_id"]?.stringValue {
                pendingClarify = nil
            }

        case GatewayEvent.Kind.sudoRequest:
            pendingSudo = SudoRequest(event: event)

        case GatewayEvent.Kind.sudoExpire:
            if pendingSudo?.requestID == event.payload["request_id"]?.stringValue {
                pendingSudo = nil
            }

        case GatewayEvent.Kind.secretRequest:
            pendingSecret = SecretRequest(event: event)

        case GatewayEvent.Kind.secretExpire:
            if pendingSecret?.requestID == event.payload["request_id"]?.stringValue {
                pendingSecret = nil
            }

        case GatewayEvent.Kind.error:
            let text = event.payload["message"]?.stringValue
                ?? event.payload["error"]?.stringValue
                ?? "Unknown server error"
            items.append(.notice(SystemNotice(id: nextLiveID("error"), text: text, level: .error)))

        case GatewayEvent.Kind.notificationShow:
            if let text = event.payload["message"]?.stringValue
                ?? event.payload["text"]?.stringValue
            {
                items.append(.notice(SystemNotice(id: nextLiveID("notice"), text: text)))
            }

        default:
            if event.type.hasPrefix(GatewayEvent.Kind.subagentPrefix) {
                applySubagent(event)
            }
            // Unknown event types are silently tolerated (open set).
        }
    }

    // MARK: Prompt clearing (call after a response is confirmed delivered)

    // Identity-guarded: while a response RPC is suspended, a NEWER request
    // can replace the pending one (actor reentrancy) — the old response must
    // not clear a prompt it didn't answer. Approval has no request_id (at
    // most one in flight per session), so it matches by value.

    public func clearApproval(matching request: ApprovalRequest) {
        if pendingApproval == request { pendingApproval = nil }
    }

    public func clearClarify(requestID: String) {
        if pendingClarify?.requestID == requestID { pendingClarify = nil }
    }

    public func clearSudo(requestID: String) {
        if pendingSudo?.requestID == requestID { pendingSudo = nil }
    }

    public func clearSecret(requestID: String) {
        if pendingSecret?.requestID == requestID { pendingSecret = nil }
    }

    // MARK: Assistant bubbles

    @discardableResult
    private func openBubble() -> Int {
        if let index = openBubbleIndex { return index }
        items.append(
            .assistant(
                AssistantMessage(
                    id: nextLiveID("assistant"), isStreaming: true, timestamp: Date())))
        openBubbleIndex = items.count - 1
        return items.count - 1
    }

    private func sealOpenBubble() {
        guard let index = openBubbleIndex, case .assistant(var bubble) = items[index] else {
            openBubbleIndex = nil
            return
        }
        bubble.isStreaming = false
        items[index] = .assistant(bubble)
        openBubbleIndex = nil
    }

    private func appendToBubble(text: String = "", reasoning: String = "") {
        guard !text.isEmpty || !reasoning.isEmpty else { return }
        let index = openBubbleIndex ?? openBubble()
        guard case .assistant(var bubble) = items[index] else { return }
        bubble.text += text
        bubble.reasoning += reasoning
        items[index] = .assistant(bubble)
    }

    /// `message.interim {text, already_streamed}` seals the current bubble;
    /// more bubbles may follow within the same turn.
    private func sealInterim(_ payload: JSONValue) {
        let index = openBubbleIndex ?? openBubble()
        guard case .assistant(var bubble) = items[index] else { return }
        if payload["already_streamed"]?.truthy != true,
            let text = payload["text"]?.stringValue, !text.isEmpty
        {
            bubble.text = text
        }
        bubble.isStreaming = false
        bubble.isInterim = true
        items[index] = .assistant(bubble)
        openBubbleIndex = nil
    }

    /// `message.complete` — terminal for this message (the turn may chain;
    /// `session.info.running == false` is the true end-of-turn).
    private func completeTurnMessage(_ payload: JSONValue) {
        let status = payload["status"]?.stringValue
        let finalText = payload["text"]?.stringValue ?? ""

        var index = openBubbleIndex
        if index == nil, !finalText.isEmpty {
            index = openBubble()
        }

        if let index, case .assistant(var bubble) = items[index] {
            if status == "error" {
                // Keep partial streamed text; surface the error alongside.
                let errorText = payload["error"]?.stringValue ?? "The turn failed."
                if payload["partial"]?.truthy != true, bubble.text.isEmpty, !finalText.isEmpty {
                    bubble.text = finalText
                }
                bubble.error = errorText
                lastError = errorText
            } else if bubble.text.isEmpty, !finalText.isEmpty {
                // Nothing streamed into this bubble (non-streaming provider,
                // or a reconnect ate the deltas): use the final text. When
                // text DID stream, keep it — `text` here is the whole turn's
                // reply, and earlier bubbles sealed at tool boundaries
                // already hold their parts of it.
                bubble.text = finalText
            }
            bubble.isStreaming = false
            items[index] = .assistant(bubble)
        } else if status == "error" {
            let errorText = payload["error"]?.stringValue ?? "The turn failed."
            lastError = errorText
            items.append(
                .notice(SystemNotice(id: nextLiveID("error"), text: errorText, level: .error)))
        }
        openBubbleIndex = nil

        if let usage = TurnUsage(json: payload["usage"]) {
            totalUsage.add(usage)
        }
    }

    // MARK: Tool rows

    private func startTool(_ payload: JSONValue) {
        let toolID = payload["tool_id"]?.stringValue ?? nextLiveID("toolid")
        let row = ToolActivity(
            id: nextLiveID("tool"),
            toolID: toolID,
            name: payload["name"]?.stringValue ?? "tool",
            context: payload["context"]?.stringValue ?? payload["preview"]?.stringValue,
            argsText: payload["args_text"]?.stringValue,
            isRunning: true,
            timestamp: Date())
        items.append(.tool(row))
        toolRowIndex[toolID] = items.count - 1
    }

    private func progressTool(_ payload: JSONValue) {
        guard let toolID = payload["tool_id"]?.stringValue,
            let index = toolRowIndex[toolID],
            case .tool(var row) = items[index]
        else { return }
        if let context = payload["context"]?.stringValue ?? payload["text"]?.stringValue {
            row.context = context
        }
        items[index] = .tool(row)
    }

    private func completeTool(_ payload: JSONValue) {
        guard let toolID = payload["tool_id"]?.stringValue else { return }
        // A tool.complete for a row we never saw start (reconnect mid-turn)
        // creates the row collapsed.
        let index: Int
        if let existing = toolRowIndex[toolID] {
            index = existing
        } else {
            startTool(payload)
            index = items.count - 1
        }
        guard case .tool(var row) = items[index] else { return }
        if let name = payload["name"]?.stringValue { row.name = name }
        row.summary = payload["summary"]?.stringValue ?? row.summary
        row.resultText = payload["result_text"]?.stringValue
            ?? payload["result"]?.stringValue
            ?? row.resultText
        row.inlineDiff = payload["inline_diff"]?.stringValue ?? row.inlineDiff
        row.durationSeconds = payload["duration_s"]?.doubleValue ?? row.durationSeconds
        if row.argsText == nil { row.argsText = payload["args_text"]?.stringValue }
        row.isRunning = false
        items[index] = .tool(row)
        toolRowIndex.removeValue(forKey: toolID)
    }

    // MARK: Subagents (v1: flattened, labeled rows)

    private func applySubagent(_ event: GatewayEvent) {
        let payload = event.payload
        let key = payload["subagent_id"]?.stringValue
            ?? "task-\(payload["task_index"]?.intValue ?? 0)"
        let label = subagentLabel(payload)

        switch event.type {
        case "subagent.start":
            let row = ToolActivity(
                id: nextLiveID("subagent"),
                name: "subagent",
                context: payload["goal"]?.stringValue ?? payload["text"]?.stringValue,
                isRunning: true,
                subagentLabel: label,
                subagentID: key,
                timestamp: Date())
            items.append(.tool(row))
            subagentRowIndex[key] = items.count - 1

        case "subagent.tool":
            guard let index = subagentRowIndex[key], case .tool(var row) = items[index]
            else { return }
            let toolName = payload["tool_name"]?.stringValue ?? "tool"
            let preview = payload["tool_preview"]?.stringValue
                ?? payload["text"]?.stringValue ?? ""
            row.context = preview.isEmpty ? toolName : "\(toolName): \(preview)"
            items[index] = .tool(row)

        case "subagent.complete":
            guard let index = subagentRowIndex.removeValue(forKey: key),
                case .tool(var row) = items[index]
            else { return }
            row.summary = payload["summary"]?.stringValue
                ?? payload["text"]?.stringValue ?? row.context
            row.durationSeconds = payload["duration_seconds"]?.doubleValue
            row.isRunning = false
            items[index] = .tool(row)

        default:
            break  // subagent.thinking and friends: no v1 rendering
        }
    }

    private func subagentLabel(_ payload: JSONValue) -> String {
        let index = payload["task_index"]?.intValue ?? 0
        let count = payload["task_count"]?.intValue ?? 1
        return count > 1 ? "Subagent \(index + 1)/\(count)" : "Subagent"
    }

    // MARK: session.info

    private func applySessionInfo(_ payload: JSONValue) {
        // Ignore lazy placeholders (no real state yet).
        if payload["lazy"]?.truthy == true { return }

        if let newTitle = payload["title"]?.stringValue, !newTitle.isEmpty { title = newTitle }
        if let newModel = payload["model"]?.stringValue, !newModel.isEmpty { model = newModel }
        if let profile = payload["profile_name"]?.stringValue, !profile.isEmpty {
            profileName = profile
        }
        if let stored = payload["stored_session_id"]?.stringValue, !stored.isEmpty {
            storedSessionID = stored
        }

        guard let runningFlag = payload["running"] else { return }
        // True end-of-turn: seal any open bubble, clear transient state.
        setRunning(runningFlag.truthy)
    }
}
