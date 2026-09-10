import Foundation

/// Gateway support for Bot Mode (the desktop `hermes-bots` surface).
///
/// Bot Mode is built on the `profiles.*` WS RPC family, which landed after
/// desktop contract 6 — so its presence cannot be inferred from the contract
/// number alone. The reliable signal is the RPC door itself: `profiles.list`
/// answers on a supporting gateway and returns JSON-RPC -32601 (method not
/// found) on an older one.
public enum BotModeSupport {
    /// Maps a `profiles.list` probe failure to a support verdict.
    ///
    /// - `false`: the gateway answered "unknown method" — definitively
    ///   unsupported until the backend is updated.
    /// - `nil`: transport-shaped failure (timeout, dropped socket, other RPC
    ///   error). Unknown — don't cache a verdict; re-probe next connection.
    public static func verdict(from error: Error) -> Bool? {
        if case HermesError.rpcError(HermesError.RPCCode.methodNotFound, _) = error {
            return false
        }
        return nil
    }
}

// MARK: - Roster models

/// A compact session reference on a `profiles.list` row: the profile's
/// canonical "Bot Chat" (`canonical_session`) or its newest human-facing
/// conversation (`last_session`).
public struct BotSessionStub: Sendable, Equatable, Hashable {
    /// Durable registry row id — what the roster identifies the chat by.
    public var storedID: String
    /// Live tip of the compression lineage — what `session.resume` should
    /// take. Server-resolved on every listing; never cache it across opens.
    public var resolvedID: String?
    public var title: String?
    public var preview: String?
    public var lastActive: Date?
    public var messageCount: Int?

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        storedID = id
        resolvedID = json["resolved_id"]?.stringValue
        title = json["title"]?.stringValue
        preview = json["preview"]?.stringValue
        if let epoch = json["last_active"]?.doubleValue, epoch > 0 {
            lastActive = Date(timeIntervalSince1970: epoch)
        }
        messageCount = json["message_count"]?.intValue
    }
}

/// One row of the Bot Mode roster: a Hermes profile plus the presentation
/// metadata the desktop's hermes-bots plugin stores under
/// `ui_meta['hermes-bots']` (backend-synced, so Mercury paints the same
/// roster as every desktop connected to this gateway).
public struct BotSummary: Sendable, Equatable, Hashable, Identifiable {
    public var name: String
    public var isDefault: Bool
    public var model: String?
    public var provider: String?
    public var profileDescription: String?
    public var displayName: String?
    public var skillCount: Int
    /// Server has an avatar image for this profile (`profiles.get_asset`).
    public var hasAvatar: Bool

    // ui_meta['hermes-bots'] — all optional; absent on profiles never touched
    // by Bot Mode.
    public var metaTitle: String?
    public var metaDescription: String?
    /// Geometric face vocabulary: circle / squircle / pill / triangle /
    /// hexagon / cloud / drop (plus render-only legacy values like
    /// `blobatar:*` and `sigil-N` that unknown clients draw as a circle).
    public var shape: String?
    /// CSS hex color (e.g. `#8b5cf6`); absent means hash one from the name.
    public var colorHex: String?
    public var hidden: Bool
    public var pinned: Bool

    public var lastSession: BotSessionStub?
    /// The profile's canonical "Bot Chat" — identity is the session NAME,
    /// resolved server-side on every listing (no client-side pointer).
    public var canonicalSession: BotSessionStub?
    /// Newest kanban/tool worker activity — a liveness signal for "working
    /// now" affordances; worker sessions never appear in session lists.
    public var workerLastActive: Date?

    public var id: String { name }

    /// Display title, matching the desktop's precedence: Bot Mode title,
    /// then the profile's display name, then the raw profile name.
    public var title: String {
        for candidate in [metaTitle, displayName] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                return candidate
            }
        }
        return name
    }

    /// Latest-message excerpt for the roster row: the canonical chat's
    /// preview wins (it is the row's click target), else the newest
    /// conversation's.
    public var preview: String? {
        canonicalSession?.preview?.isEmpty == false
            ? canonicalSession?.preview : lastSession?.preview
    }

    /// Newest activity across the canonical chat, the latest conversation,
    /// and any live worker — what the roster orders by.
    public var lastActivity: Date? {
        [canonicalSession?.lastActive, lastSession?.lastActive, workerLastActive]
            .compactMap { $0 }
            .max()
    }

    public init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        isDefault = json["is_default"]?.truthy ?? false
        model = json["model"]?.stringValue
        provider = json["provider"]?.stringValue
        profileDescription = json["description"]?.stringValue
        displayName = json["display_name"]?.stringValue
        skillCount = json["skill_count"]?.intValue ?? 0
        hasAvatar = json["has_avatar"]?.truthy ?? false

        let meta = json["ui_meta"]?["hermes-bots"]
        metaTitle = meta?["title"]?.stringValue
        metaDescription = meta?["description"]?.stringValue
        shape = meta?["shape"]?.stringValue
        colorHex = meta?["color"]?.stringValue
        hidden = meta?["hidden"]?.truthy ?? false
        pinned = meta?["pinned"]?.truthy ?? false

        lastSession = json["last_session"].flatMap(BotSessionStub.init(json:))
        canonicalSession = json["canonical_session"].flatMap(BotSessionStub.init(json:))
        if let epoch = json["worker_session"]?["last_active"]?.doubleValue, epoch > 0 {
            workerLastActive = Date(timeIntervalSince1970: epoch)
        }
    }
}

/// A profile asset fetched via `profiles.get_asset` (today: `avatar`).
public struct ProfileAsset: Sendable, Equatable {
    public var mime: String
    public var data: Data

    /// Parses the RPC result. `found: false` is a normal absence → nil.
    /// A malformed data URL on a `found: true` result also returns nil —
    /// the roster's geometric fallback face covers both.
    public init?(json: JSONValue) {
        guard json["found"]?.truthy == true,
            let dataURL = json["data"]?.stringValue,
            let comma = dataURL.firstIndex(of: ","),
            dataURL.hasPrefix("data:"),
            let decoded = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        else { return nil }
        data = decoded
        mime = json["mime"]?.stringValue
            ?? String(dataURL.dropFirst(5).prefix(while: { $0 != ";" && $0 != "," }))
    }
}

// MARK: - Canonical-chat composer policy

/// The canonical Bot Chat is a forever-chat: `/new` (or `/reset`) would fork
/// the relationship into a scratch session — the one thing Bot Mode promises
/// never happens. The desktop composer reroutes both to `/compact` (fresh
/// working context, same conversation); Mercury applies the same policy.
public enum BotChatPolicy {
    /// The replacement text when `text` must be rerouted inside a canonical
    /// Bot Chat, or nil to send it unchanged. Only the leading command token
    /// matters — arguments (e.g. `/new some title`) don't rescue a fork.
    public static func reroute(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init)
        switch command?.lowercased() {
        case "/new", "/reset":
            return "/compact"
        default:
            return nil
        }
    }
}

// MARK: - RPCs

extension HermesConnection {
    /// Probe whether this gateway speaks the `profiles.*` RPC family.
    ///
    /// Uses `profiles.list` with `include_sessions: false` — the cheap form
    /// that skips the per-profile state.db walks (last-session previews,
    /// canonical-chat resolution), so the probe stays fast even on gateways
    /// with many profiles.
    public func probeBotModeSupport(timeout: TimeInterval = 20) async -> Bool? {
        do {
            _ = try await request(
                "profiles.list",
                params: .object(["include_sessions": .bool(false)]),
                timeout: timeout)
            return true
        } catch {
            return BotModeSupport.verdict(from: error)
        }
    }

    /// The Bot Mode roster: every profile with its `ui_meta['hermes-bots']`
    /// presentation, latest-conversation preview, and server-resolved
    /// canonical Bot Chat. The session walk makes this the expensive form —
    /// callers should cache and refresh, not poll.
    public func listBots(timeout: TimeInterval = 60) async throws -> [BotSummary] {
        let result = try await request(
            "profiles.list",
            params: .object(["include_sessions": .bool(true)]),
            timeout: timeout)
        return result["profiles"]?.arrayValue?.compactMap(BotSummary.init(json:)) ?? []
    }

    /// A profile's avatar image, or nil when the profile has none
    /// (`found: false`).
    public func profileAvatar(
        name: String, timeout: TimeInterval = 30
    ) async throws -> ProfileAsset? {
        let result = try await request(
            "profiles.get_asset",
            params: .object(["name": .string(name), "asset": .string("avatar")]),
            timeout: timeout)
        return ProfileAsset(json: result)
    }
}
