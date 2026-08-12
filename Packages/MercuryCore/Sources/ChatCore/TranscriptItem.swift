import Foundation
import MercuryKit

/// One renderable row of a session transcript, reduced from the gateway
/// event stream and/or REST hydration.
public enum TranscriptItem: Sendable, Equatable, Identifiable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case tool(ToolActivity)
    case notice(SystemNotice)

    public var id: String {
        switch self {
        case .user(let m): return m.id
        case .assistant(let m): return m.id
        case .tool(let t): return t.id
        case .notice(let n): return n.id
        }
    }
}

public struct UserMessage: Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    /// Durable backend `messages.id` once persisted (hydration dedupe key).
    public var rowID: Int?
    public var timestamp: Date?

    public init(id: String, text: String, rowID: Int? = nil, timestamp: Date? = nil) {
        self.id = id
        self.text = text
        self.rowID = rowID
        self.timestamp = timestamp
    }
}

public struct AssistantMessage: Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    /// Collapsible "thinking" text fed by reasoning.delta / thinking.delta.
    public var reasoning: String
    /// Still receiving deltas (spinner/caret state).
    public var isStreaming: Bool
    /// Sealed mid-turn commentary (`message.interim`) — more bubbles may
    /// follow in the same turn.
    public var isInterim: Bool
    /// Error text from `message.complete {status:"error"}`. When the turn
    /// was partial the streamed `text` above is kept and this is shown
    /// alongside it.
    public var error: String?
    public var rowID: Int?
    public var timestamp: Date?

    public init(
        id: String,
        text: String = "",
        reasoning: String = "",
        isStreaming: Bool = false,
        isInterim: Bool = false,
        error: String? = nil,
        rowID: Int? = nil,
        timestamp: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.reasoning = reasoning
        self.isStreaming = isStreaming
        self.isInterim = isInterim
        self.error = error
        self.rowID = rowID
        self.timestamp = timestamp
    }
}

public struct ToolActivity: Sendable, Equatable, Identifiable {
    public var id: String
    /// Gateway `tool_id`; nil for rows rebuilt from hydration.
    public var toolID: String?
    public var name: String
    /// 80-char display preview of the call (`context`).
    public var context: String?
    /// Full argument text for the expanded row.
    public var argsText: String?
    public var summary: String?
    public var resultText: String?
    public var inlineDiff: String?
    public var durationSeconds: Double?
    public var isRunning: Bool
    /// Label of the owning subagent when this activity arrived as
    /// `subagent.*` (v1 flattens nested activity to labeled rows).
    public var subagentLabel: String?
    /// Gateway `subagent_id` — the reducer identity progress/completion
    /// events are keyed by. The label above is presentation only and NOT
    /// unique ("Subagent 1/2" collides across turns).
    public var subagentID: String?
    public var rowID: Int?
    public var timestamp: Date?

    public init(
        id: String,
        toolID: String? = nil,
        name: String,
        context: String? = nil,
        argsText: String? = nil,
        summary: String? = nil,
        resultText: String? = nil,
        inlineDiff: String? = nil,
        durationSeconds: Double? = nil,
        isRunning: Bool = false,
        subagentLabel: String? = nil,
        subagentID: String? = nil,
        rowID: Int? = nil,
        timestamp: Date? = nil
    ) {
        self.id = id
        self.toolID = toolID
        self.name = name
        self.context = context
        self.argsText = argsText
        self.summary = summary
        self.resultText = resultText
        self.inlineDiff = inlineDiff
        self.durationSeconds = durationSeconds
        self.isRunning = isRunning
        self.subagentLabel = subagentLabel
        self.subagentID = subagentID
        self.rowID = rowID
        self.timestamp = timestamp
    }
}

public struct SystemNotice: Sendable, Equatable, Identifiable {
    public enum Level: Sendable, Equatable {
        case info
        case error
    }

    public var id: String
    public var text: String
    public var level: Level

    public init(id: String, text: String, level: Level = .info) {
        self.id = id
        self.text = text
        self.level = level
    }
}
