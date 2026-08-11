import Foundation

// MARK: - Server status

public struct ServerStatus: Sendable, Equatable {
    public var version: String?
    public var authRequired: Bool
    public var activeSessions: Int?
    public var raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
        self.version = raw["version"]?.stringValue
        self.authRequired = raw["auth_required"]?.truthy ?? false
        self.activeSessions = raw["active_sessions"]?.intValue
    }
}

// MARK: - Profiles

public struct ProfileInfo: Sendable, Equatable, Identifiable {
    public var name: String
    public var path: String?
    public var isDefault: Bool
    public var model: String?
    public var provider: String?
    public var skillCount: Int?
    public var hasEnv: Bool

    public var id: String { name }

    public init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        self.path = json["path"]?.stringValue
        self.isDefault = json["is_default"]?.truthy ?? false
        self.model = json["model"]?.stringValue
        self.provider = json["provider"]?.stringValue
        self.skillCount = json["skill_count"]?.intValue
        self.hasEnv = json["has_env"]?.truthy ?? false
    }
}

// MARK: - Sessions

/// A row from the session lists (`/api/sessions`, `/api/profiles/sessions`,
/// `session.list`, `projects.tree` previews). The id here is always the
/// durable **stored** id (`YYYYMMDD_HHMMSS_<hex>`), never a runtime id.
public struct SessionSummary: Sendable, Equatable, Identifiable {
    public var storedID: String
    public var title: String?
    public var cwd: String?
    public var gitRepoRoot: String?
    public var gitBranch: String?
    public var profile: String?
    public var pinned: Bool
    public var updatedAt: Date?
    public var messageCount: Int?

    public var id: String { storedID }

    public init?(json: JSONValue) {
        // Different surfaces name the id differently.
        guard
            let storedID = json["session_id"]?.stringValue
                ?? json["id"]?.stringValue
                ?? json["stored_session_id"]?.stringValue,
            !storedID.isEmpty
        else { return nil }
        self.storedID = storedID
        self.title = json["title"]?.stringValue
        self.cwd = json["cwd"]?.stringValue
        self.gitRepoRoot = json["git_repo_root"]?.stringValue
        self.gitBranch = json["git_branch"]?.stringValue
        self.profile = json["profile"]?.stringValue
        self.pinned = json["pinned"]?.truthy ?? false
        self.messageCount = json["message_count"]?.intValue
        // Timestamps arrive as epoch seconds or ISO strings depending on
        // surface; accept both.
        if let epoch = (json["updated_at"] ?? json["last_active"] ?? json["created_at"])?
            .doubleValue
        {
            self.updatedAt = Date(timeIntervalSince1970: epoch)
        } else if let iso = (json["updated_at"] ?? json["last_active"] ?? json["created_at"])?
            .stringValue
        {
            self.updatedAt = ISO8601DateFormatter().date(from: iso)
        }
    }
}

// MARK: - Projects

public struct ProjectInfo: Sendable, Equatable, Identifiable {
    /// The Home / no-workspace bucket id used by `projects.tree`.
    public static let noProjectID = "__no_project__"

    public var id: String
    public var name: String
    public var primaryPath: String?
    public var kind: String?
    public var previewSessions: [SessionSummary]
    public var sessionCount: Int?

    public var isHomeBucket: Bool { id == Self.noProjectID }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue ?? json["project_id"]?.stringValue else {
            return nil
        }
        self.id = id
        self.name = json["name"]?.stringValue ?? json["title"]?.stringValue ?? id
        self.primaryPath =
            json["primary_path"]?.stringValue
            ?? json["path"]?.stringValue
            ?? json["root"]?.stringValue
        self.kind = json["kind"]?.stringValue ?? json["type"]?.stringValue
        self.previewSessions = (json["sessions"] ?? json["preview_sessions"])?.arrayValue?
            .compactMap(SessionSummary.init(json:)) ?? []
        self.sessionCount = json["session_count"]?.intValue
    }
}

public struct ProjectTree: Sendable, Equatable {
    public var projects: [ProjectInfo]
    public var activeID: String?
    /// Stored session ids already shown inside a project group — exclude
    /// these from the flat Recents list.
    public var scopedSessionIDs: Set<String>

    public init(json: JSONValue) {
        self.projects = json["projects"]?.arrayValue?.compactMap(ProjectInfo.init(json:)) ?? []
        self.activeID = json["active_id"]?.stringValue
        self.scopedSessionIDs = Set(
            json["scoped_session_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }
}

// MARK: - Live session handle

/// Result of `session.create` / `session.resume`.
///
/// Two-ID model: `runtimeID` is what every subsequent RPC takes but is
/// recycled on backend restart; `storedID` is the durable DB id used to
/// re-resume after any reconnect.
public struct SessionHandle: Sendable, Equatable {
    public var runtimeID: String
    public var storedID: String?
    public var cwd: String?
    public var project: String?
    public var profileName: String?
    public var model: String?
    public var title: String?
    public var desktopContract: Int?
    public var raw: JSONValue

    public init?(result: JSONValue) {
        guard let runtimeID = result["session_id"]?.stringValue, !runtimeID.isEmpty else {
            return nil
        }
        self.runtimeID = runtimeID
        self.storedID = result["stored_session_id"]?.stringValue
        let info = result["info"] ?? .null
        self.cwd = info["cwd"]?.stringValue
        self.project = info["project"]?.stringValue
        self.profileName = info["profile_name"]?.stringValue
        self.model = info["model"]?.stringValue
        self.title = info["title"]?.stringValue ?? result["title"]?.stringValue
        self.desktopContract = info["desktop_contract"]?.intValue
            ?? result["desktop_contract"]?.intValue
        self.raw = result
    }
}

// MARK: - Audio

public struct TranscriptionResult: Sendable, Equatable {
    public var transcript: String
    public var provider: String?

    /// Empty transcript = silence; a normal outcome, not an error.
    public var isSilence: Bool {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct SpokenClip: Sendable, Equatable {
    public var dataURL: String
    public var mimeType: String?
}

// MARK: - Transcript hydration

/// A persisted message row from `GET /api/sessions/{id}/messages` (the REST
/// transcript path) or a `session.resume` result's message list.
///
/// The durable row id is named `id` by REST (`SELECT *`) but `row_id` by the
/// gateway resume path — read both. Payload shapes vary by backend version,
/// so everything but `role` is optional and the raw JSON is retained.
public struct TranscriptMessage: Sendable, Equatable, Identifiable {
    public var rowID: Int?
    public var role: String
    public var text: String
    public var reasoning: String?
    public var toolName: String?
    public var toolCallID: String?
    /// Tool args/context preview for `role == "tool"` rows.
    public var context: String?
    public var displayKind: String?
    public var timestamp: Date?
    public var raw: JSONValue

    /// Stable identity for list rendering: the durable row id when the row
    /// has been persisted, else a content-derived fallback.
    public var id: String {
        if let rowID { return "row-\(rowID)" }
        let stamp = timestamp?.timeIntervalSince1970 ?? 0
        return "ephemeral-\(role)-\(stamp)-\(text.hashValue)"
    }

    public init?(json: JSONValue) {
        guard let role = json["role"]?.stringValue, !role.isEmpty else { return nil }
        self.role = role
        self.rowID = json["row_id"]?.intValue ?? json["id"]?.intValue
        // Content is usually a string; tolerate structured content by
        // falling back to a `text` field or empty (empty means "nothing",
        // never an error).
        self.text = json["content"]?.stringValue
            ?? json["text"]?.stringValue
            ?? ""
        self.reasoning = json["reasoning"]?.stringValue
            ?? json["reasoning_content"]?.stringValue
        self.toolName = json["tool_name"]?.stringValue ?? json["name"]?.stringValue
        self.toolCallID = json["tool_call_id"]?.stringValue
        self.context = json["context"]?.stringValue
        self.displayKind = json["display_kind"]?.stringValue
        if let epoch = json["timestamp"]?.doubleValue {
            self.timestamp = Date(timeIntervalSince1970: epoch)
        }
        self.raw = json
    }
}

/// One page of `GET /api/sessions/{id}/messages`. The server pages this
/// endpoint unconditionally (≤500 rows); `order == "latest"` pages are still
/// returned in chronological order.
public struct TranscriptPage: Sendable, Equatable {
    public var sessionID: String?
    public var messages: [TranscriptMessage]
    public var limit: Int?
    public var offset: Int?
    public var returned: Int?

    public init(json: JSONValue) {
        self.sessionID = json["session_id"]?.stringValue
        self.messages = json["messages"]?.arrayValue?
            .compactMap(TranscriptMessage.init(json:)) ?? []
        let pagination = json["pagination"]
        self.limit = pagination?["limit"]?.intValue
        self.offset = pagination?["offset"]?.intValue
        self.returned = pagination?["returned"]?.intValue
    }
}

// MARK: - Model options

/// One row from `model.options` (model picker).
public struct ModelOption: Sendable, Equatable, Identifiable {
    public var value: String
    public var label: String
    public var provider: String?
    public var isCurrent: Bool

    public var id: String { value }

    public init?(json: JSONValue) {
        guard
            let value = json["value"]?.stringValue
                ?? json["model"]?.stringValue
                ?? json["id"]?.stringValue,
            !value.isEmpty
        else { return nil }
        self.value = value
        self.label = json["label"]?.stringValue ?? json["name"]?.stringValue ?? value
        self.provider = json["provider"]?.stringValue
        self.isCurrent = json["current"]?.truthy ?? json["selected"]?.truthy ?? false
    }
}
