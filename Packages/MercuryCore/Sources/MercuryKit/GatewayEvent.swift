import Foundation

/// A server-push event from `/api/ws`: a JSON-RPC notification with
/// `method == "event"` whose real name is `params.type`.
public struct GatewayEvent: Sendable, Equatable {
    public var type: String
    public var sessionID: String?
    public var payload: JSONValue
    /// Per-session monotonic sequence stamp (v0.20.5+; nil from older
    /// backends). Sibling of `type` in the frame's params, NOT in `payload`.
    /// Basis of the reconnect replay contract (`session.events.since`).
    public var seq: Int?

    public init(type: String, sessionID: String?, payload: JSONValue, seq: Int? = nil) {
        self.type = type
        self.sessionID = sessionID
        self.payload = payload
        self.seq = seq
    }

    /// Well-known event names (open set — unknown types must be tolerated).
    public enum Kind {
        public static let gatewayReady = "gateway.ready"
        public static let messageStart = "message.start"
        public static let messageDelta = "message.delta"
        public static let messageInterim = "message.interim"
        public static let messageComplete = "message.complete"
        public static let thinkingDelta = "thinking.delta"
        public static let reasoningDelta = "reasoning.delta"
        public static let toolGenerating = "tool.generating"
        public static let toolStart = "tool.start"
        public static let toolProgress = "tool.progress"
        public static let toolComplete = "tool.complete"
        public static let statusUpdate = "status.update"
        public static let approvalRequest = "approval.request"
        public static let clarifyRequest = "clarify.request"
        public static let clarifyExpire = "clarify.expire"
        public static let sudoRequest = "sudo.request"
        public static let sudoExpire = "sudo.expire"
        public static let secretRequest = "secret.request"
        public static let secretExpire = "secret.expire"
        public static let mcpSetupRequest = "mcp.setup.request"
        public static let mcpSetupExpire = "mcp.setup.expire"
        public static let sessionUsage = "session.usage"
        public static let sessionInfo = "session.info"
        public static let sessionTitle = "session.title"
        public static let sessionsChanged = "sessions.changed"
        public static let notificationShow = "notification.show"
        public static let notificationClear = "notification.clear"
        public static let error = "error"
        /// Nested agent activity arrives as `subagent.*` (open sub-set).
        public static let subagentPrefix = "subagent."
    }
}

// MARK: - Typed payloads

/// `approval.request` — session-keyed: at most one is SHOWN per session;
/// answer with `approval.respond {session_id, choice, request_id?}`. The
/// server queues approvals and resolves the oldest when no `request_id` is
/// given, so pass one when the payload carries it — a queue of several must
/// not resolve a different entry than the card the user saw.
public struct ApprovalRequest: Sendable, Equatable, Identifiable {
    public var sessionID: String
    /// Present on current backends (approvals are queued server-side);
    /// absent on older ones, where session-keyed respond is exact.
    public var requestID: String?
    public var command: String?
    public var description: String?
    /// Server-derived subset of once/session/always/deny.
    public var choices: [String]

    public var id: String { requestID ?? sessionID }

    public init?(event: GatewayEvent) {
        guard event.type == GatewayEvent.Kind.approvalRequest,
            let sessionID = event.sessionID
        else { return nil }
        self.sessionID = sessionID
        self.requestID = event.payload["request_id"]?.stringValue
        self.command = event.payload["command"]?.stringValue
        self.description = event.payload["description"]?.stringValue

        if let listed = event.payload["choices"]?.arrayValue?.compactMap(\.stringValue),
            !listed.isEmpty
        {
            self.choices = listed
        } else {
            // Derive like the server does when choices is absent:
            // allow_permanent/allow_session absent mean *allowed* (!= false).
            var derived = ["once"]
            if event.payload["smart_denied"]?.truthy != true {
                if event.payload["allow_session"]?.boolValue != false { derived.append("session") }
                if event.payload["allow_permanent"]?.boolValue != false { derived.append("always") }
            }
            derived.append("deny")
            self.choices = derived
        }
    }
}

/// `clarify.request` — correlated by `request_id`; may be cleared by a
/// matching `clarify.expire`. Empty answer = skip.
///
/// Two wire shapes: the historical single question (`question`/`choices` at
/// the top level), and the batch shape (v0.20.5+) — `questions: [{qid,
/// question, choices, multi_select}]` with NO top-level question. Batch
/// answers go per question via `clarify.respond {request_id, question_id,
/// answer}` (each returns the still-unanswered `remaining` qids; the batch
/// resolves when it empties); a respond with no question_id cancels the
/// whole batch.
public struct ClarifyRequest: Sendable, Equatable, Identifiable {
    public struct Question: Sendable, Equatable, Identifiable {
        public var qid: String
        public var question: String
        public var choices: [String]
        public var multiSelect: Bool

        public var id: String { qid }
    }

    public var requestID: String
    public var sessionID: String?
    public var question: String
    /// nil/empty = free-text question.
    public var choices: [String]
    public var multiSelect: Bool
    /// Non-empty = batch shape; `question`/`choices` above are then empty.
    public var questions: [Question]
    /// Batch answers already locked server-side (qid → answer) — present on
    /// the resume payload's `pending_clarify` snapshot after a reconnect.
    public var lockedAnswers: [String: String]

    public var id: String { requestID }
    public var isBatch: Bool { !questions.isEmpty }

    public init?(event: GatewayEvent) {
        guard event.type == GatewayEvent.Kind.clarifyRequest,
            let requestID = event.payload["request_id"]?.stringValue
        else { return nil }
        self.requestID = requestID
        self.sessionID = event.sessionID
        self.question = event.payload["question"]?.stringValue ?? ""
        self.choices = Self.cleanChoices(event.payload["choices"])
        self.multiSelect = event.payload["multi_select"]?.truthy ?? false
        self.questions =
            event.payload["questions"]?.arrayValue?.compactMap { entry -> Question? in
                guard let qid = entry["qid"]?.stringValue, !qid.isEmpty else { return nil }
                return Question(
                    qid: qid,
                    question: entry["question"]?.stringValue ?? "",
                    choices: Self.cleanChoices(entry["choices"]),
                    multiSelect: entry["multi_select"]?.truthy ?? false)
            } ?? []
        var locked: [String: String] = [:]
        if let answers = event.payload["answers"]?.objectValue {
            for (qid, value) in answers { locked[qid] = value.stringValue ?? "" }
        }
        self.lockedAnswers = locked
    }

    private static func cleanChoices(_ json: JSONValue?) -> [String] {
        json?.arrayValue?
            .compactMap(\.stringValue)
            .filter { !$0.isEmpty && $0.count <= 200 && !$0.contains("\n") } ?? []
    }
}

/// `sudo.request` — the agent needs the user's sudo password. Correlated by
/// `request_id`; answer with `sudo.respond {request_id, password}`. The value
/// must never be logged or persisted. Empty answer = decline.
public struct SudoRequest: Sendable, Equatable, Identifiable {
    public var requestID: String
    public var sessionID: String?

    public var id: String { requestID }

    public init?(event: GatewayEvent) {
        guard event.type == GatewayEvent.Kind.sudoRequest,
            let requestID = event.payload["request_id"]?.stringValue
        else { return nil }
        self.requestID = requestID
        self.sessionID = event.sessionID
    }
}

/// `secret.request` — a skill wants a credential captured into `env_var`.
/// Correlated by `request_id`; answer with `secret.respond {request_id,
/// value}`. The value must never be logged or persisted. Empty answer = skip.
public struct SecretRequest: Sendable, Equatable, Identifiable {
    public var requestID: String
    public var sessionID: String?
    public var prompt: String
    public var envVar: String?

    public var id: String { requestID }

    public init?(event: GatewayEvent) {
        guard event.type == GatewayEvent.Kind.secretRequest,
            let requestID = event.payload["request_id"]?.stringValue
        else { return nil }
        self.requestID = requestID
        self.sessionID = event.sessionID
        self.prompt = event.payload["prompt"]?.stringValue ?? ""
        self.envVar = event.payload["env_var"]?.stringValue
    }
}

/// `mcp.setup.request` — the agent's `setup_mcp` tool proposes installing,
/// enabling, or authorizing an MCP server and blocks (up to 10 minutes) on
/// the user's consent. Correlated by `request_id`; may be cleared by a
/// matching `mcp.setup.expire`. Answer with `mcp.setup.respond {request_id,
/// result}` where `result` is a JSON string `{status, server, detail?}` and
/// status ∈ installed|enabled|authorized|declined|error.
public struct McpSetupRequest: Sendable, Equatable, Identifiable {
    public var requestID: String
    public var sessionID: String?
    /// Catalog or config name of the MCP server.
    public var server: String
    /// One of install/enable/authorize.
    public var action: String
    /// The agent's one-line rationale, for display on the card.
    public var reason: String

    public var id: String { requestID }

    public init?(event: GatewayEvent) {
        guard event.type == GatewayEvent.Kind.mcpSetupRequest,
            let requestID = event.payload["request_id"]?.stringValue
        else { return nil }
        self.requestID = requestID
        self.sessionID = event.sessionID
        self.server = event.payload["server"]?.stringValue ?? ""
        self.action = event.payload["action"]?.stringValue ?? "install"
        self.reason = event.payload["reason"]?.stringValue ?? ""
    }
}

/// Usage counters from `message.complete` / `session.usage`. These are
/// SESSION-CUMULATIVE snapshots (the server reports the agent's lifetime
/// counters, not per-turn deltas) — the latest snapshot replaces the
/// previous one; never sum them.
public struct TurnUsage: Sendable, Equatable {
    public var calls: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int
    /// Current context-window occupancy gauge. Only present when the
    /// backend's compressor reports real per-window numbers.
    public var contextUsed: Int?
    public var contextMax: Int?
    public var contextPercent: Int?

    public init?(json: JSONValue?) {
        guard let json, json.objectValue != nil else { return nil }
        self.calls = json["calls"]?.intValue ?? 0
        self.inputTokens = json["input"]?.intValue ?? 0
        self.outputTokens = json["output"]?.intValue ?? 0
        self.totalTokens = json["total"]?.intValue
            ?? (self.inputTokens + self.outputTokens)
        self.contextUsed = json["context_used"]?.intValue
        self.contextMax = json["context_max"]?.intValue
        self.contextPercent = json["context_percent"]?.intValue
    }
}
