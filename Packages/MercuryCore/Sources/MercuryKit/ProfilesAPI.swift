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

    /// The complete `ui_meta['hermes-bots']` object as stored. Writes to
    /// `ui_meta` merge KEY-WISE at the top level — sending the namespace
    /// replaces the whole object — so editors must read-modify-write from
    /// this, never send a partial patch.
    public var uiMetaRaw: JSONValue?
    /// The gateway's CAS revision for the `hermes-bots` ui_meta key
    /// (`ui_meta_revisions`). Pass it back on writes so a concurrent edit
    /// from another client conflicts instead of being clobbered. nil on
    /// gateways predating gateway-owned CAS.
    public var uiMetaRevision: Int?

    public var id: String { name }

    // JSONValue (uiMetaRaw) is Equatable but not Hashable; identity + the
    // CAS revision is plenty of hash discrimination for roster diffing.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(uiMetaRevision)
        hasher.combine(canonicalSession)
        hasher.combine(lastSession)
    }

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
        uiMetaRaw = meta?.objectValue != nil ? meta : nil
        uiMetaRevision = json["ui_meta_revisions"]?["hermes-bots"]?.intValue
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

// MARK: - Routines (cron)

/// One cron job as `cron.manage` reports it. Deliberately its own type: the
/// wire keys the id as `job_id`, carries the schedule as a plain string, and
/// splits errors into separate fields (desktop parity).
public struct CronJob: Sendable, Equatable, Identifiable {
    public var jobID: String
    /// Bot routines are namespaced `[bot:<name>] <routine>`.
    public var name: String
    public var schedule: String?
    public var prompt: String?
    public var enabled: Bool
    public var state: String?
    public var lastStatus: String?
    public var lastRunAt: Date?
    public var nextRunAt: Date?
    public var lastFireError: String?
    public var deliver: String?

    public var id: String { jobID }

    /// The routine's display name with any `[bot:<name>]` namespace stripped.
    public var displayName: String {
        guard name.hasPrefix("[bot:"), let close = name.firstIndex(of: "]") else {
            return name
        }
        let stripped = name[name.index(after: close)...]
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? name : stripped
    }

    /// True when the `[bot:<name>]` namespace matches `botName` — the safe
    /// client-side filter for gateways that ignore the profile scope.
    public func belongsToBot(named botName: String) -> Bool {
        name.lowercased().hasPrefix("[bot:\(botName.lowercased())]")
    }

    public init?(json: JSONValue) {
        guard let jobID = json["job_id"]?.stringValue ?? json["id"]?.stringValue,
            !jobID.isEmpty
        else { return nil }
        self.jobID = jobID
        name = json["name"]?.stringValue ?? jobID
        schedule = json["schedule"]?.stringValue
        prompt = json["prompt"]?.stringValue ?? json["prompt_preview"]?.stringValue
        enabled = json["enabled"]?.truthy ?? true
        state = json["state"]?.stringValue
        lastStatus = json["last_status"]?.stringValue
        lastFireError = json["last_fire_error"]?.stringValue
        deliver = json["deliver"]?.stringValue
        lastRunAt = Self.date(json["last_run_at"])
        nextRunAt = Self.date(json["next_run_at"])
    }

    /// Cron timestamps arrive as ISO strings (with or without fractional
    /// seconds) or epoch seconds, depending on the store's age.
    private static func date(_ value: JSONValue?) -> Date? {
        if let epoch = value?.doubleValue, epoch > 0 {
            return Date(timeIntervalSince1970: epoch)
        }
        guard let iso = value?.stringValue, !iso.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
}

/// A `cron.manage list` result: the jobs plus whether the gateway honored the
/// profile scope (`scoped`). When it didn't (older gateway), callers must
/// apply the safe `[bot:<name>]` namespace filter themselves.
public struct CronJobList: Sendable, Equatable {
    public var jobs: [CronJob]
    public var scopedToProfile: Bool
}

// MARK: - Bot meta writes

/// Outcome of a `profiles.configure` ui_meta write.
public enum BotMetaWriteOutcome: Sendable, Equatable {
    /// The gateway confirmed the write (`applied.ui_meta == true`).
    case persisted
    /// Per-key CAS rejected the write: another client changed the meta since
    /// this roster row was read. Reload and re-apply.
    case conflict
    /// The gateway answered but did not confirm (`applied.ui_meta` false or
    /// missing) — treat as failed rather than assuming success.
    case failed
}

// MARK: - Canonical-chat composer policy

/// The canonical Bot Chat is a forever-chat: `/new` (or `/reset`) would fork
/// the relationship into a scratch session — the one thing Bot Mode promises
/// never happens. Those commands (and an explicit `/compact`) run REAL
/// compression via the `session.compress` RPC instead — `prompt.submit`
/// treats slash text as an ordinary message, so rewriting the string alone
/// would only send "/compact" to the model.
public enum BotChatPolicy {
    /// The canonical registry title. (profile, "Bot Chat") IS the bot's
    /// forever-chat identity — the gateway resolves by this exact name, so
    /// renaming a canonical chat severs the relationship.
    public static let canonicalTitle = "Bot Chat"

    /// True when `text` must run compression instead of being submitted as a
    /// prompt inside a canonical Bot Chat. Only the leading command token
    /// matters — arguments (e.g. `/new some title`) don't rescue a fork.
    public static func isCompactCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init)
        switch command?.lowercased() {
        case "/new", "/reset", "/compact":
            return true
        default:
            return false
        }
    }

    /// Whether a listed/looked-up session row is a canonical Bot Chat.
    /// Exact-lookup gateways report the durable lineage root's title as
    /// `root_title`; windowed listings carry only `title` (desktop parity).
    public static func isCanonicalRow(rootTitle: String?, title: String?) -> Bool {
        let root = rootTitle?.trimmingCharacters(in: .whitespaces) ?? ""
        if !root.isEmpty { return root == canonicalTitle }
        return title?.trimmingCharacters(in: .whitespaces) == canonicalTitle
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

    /// Authoritative per-open canonical Bot Chat lookup: `session.list`'s
    /// exact-title fast path on the bot's profile. The gateway resolves the
    /// compression lineage to the live tip (`resolved_id`), resurrects
    /// accidentally-archived canonical rows, and answers `sessions: []` for
    /// confirmed absence. Hidden rows resolve (canonical chats are born
    /// hidden on the desktop). Throws on transport/RPC failure — callers
    /// must fail CLOSED there: a failed registry lookup never reads as
    /// "no Bot Chat exists", because creating on that misreading is how a
    /// forever-chat forks.
    public func findCanonicalBotChat(
        profile: String, timeout: TimeInterval = 30
    ) async throws -> BotSessionStub? {
        let result = try await request(
            "session.list",
            params: .object([
                "profile": .string(profile),
                "title": .string(BotChatPolicy.canonicalTitle),
                "include_hidden": .bool(true),
                "limit": .number(200),
            ]),
            timeout: timeout)
        let rows = result["sessions"]?.arrayValue ?? []
        return rows.lazy
            .filter {
                BotChatPolicy.isCanonicalRow(
                    rootTitle: $0["root_title"]?.stringValue,
                    title: $0["title"]?.stringValue)
            }
            .compactMap(BotSessionStub.init(json:))
            .first
    }

    /// Real context compression for a live session — the RPC behind the
    /// desktop's `/compact`. (`prompt.submit` treats slash text as an
    /// ordinary message, so this is the only way to actually compress.)
    /// Returns the result's `status`: "compressed", "pending" (still running
    /// server-side; the transcript refreshes when it lands), or a host-owned
    /// value like "aborted".
    public func compressSession(
        sessionID: String, timeout: TimeInterval = 300
    ) async throws -> String {
        let result = try await request(
            "session.compress",
            params: .object(["session_id": .string(sessionID)]),
            timeout: timeout)
        return result["status"]?.stringValue ?? "compressed"
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

    /// Store (or clear) a profile's avatar. `dataURL` must be a PNG/JPEG/WebP
    /// data URL ≤ 2MB — downscale on-device first.
    public func setProfileAvatar(
        name: String, dataURL: String?, timeout: TimeInterval = 60
    ) async throws {
        var params: [String: JSONValue] = [
            "name": .string(name), "asset": .string("avatar"),
        ]
        if let dataURL {
            params["data"] = .string(dataURL)
        } else {
            params["clear"] = .bool(true)
        }
        _ = try await request("profiles.set_asset", params: .object(params), timeout: timeout)
    }

    /// Write a bot's COMPLETE `ui_meta['hermes-bots']` object. The gateway
    /// merges ui_meta key-wise at the top level, so `meta` replaces the whole
    /// namespace — build it by modifying the roster row's `uiMetaRaw`, never
    /// from scratch. `expectedRevision` (the row's `uiMetaRevision`) arms the
    /// per-key CAS so a concurrent desktop edit conflicts instead of being
    /// clobbered; pass nil only when the row reported no revision map.
    public func configureBotMeta(
        name: String, meta: JSONValue, expectedRevision: Int?,
        timeout: TimeInterval = 30
    ) async throws -> BotMetaWriteOutcome {
        var params: [String: JSONValue] = [
            "name": .string(name),
            "ui_meta": .object(["hermes-bots": meta]),
        ]
        if let expectedRevision {
            params["ui_meta_expected_revisions"] = .object([
                "hermes-bots": .number(Double(expectedRevision))
            ])
        }
        let result = try await request(
            "profiles.configure", params: .object(params), timeout: timeout)
        return Self.metaWriteOutcome(from: result)
    }

    /// Maps a `profiles.configure` result onto the write outcome — split out
    /// so the CAS interpretation is unit-testable.
    public static func metaWriteOutcome(from result: JSONValue) -> BotMetaWriteOutcome {
        let applied = result["applied"]
        if applied?["ui_meta_conflicts"]?.objectValue?.isEmpty == false {
            return .conflict
        }
        return applied?["ui_meta"]?.truthy == true ? .persisted : .failed
    }

    // MARK: Routines

    /// A profile's cron jobs (bot routines are named `[bot:<name>] …`).
    /// Includes paused jobs — excluding them reads as deletion in a toggle
    /// UI. `scopedToProfile` is false on gateways that ignored the profile
    /// param; apply `CronJob.belongsToBot` there.
    public func listCronJobs(
        profile: String, timeout: TimeInterval = 30
    ) async throws -> CronJobList {
        let result = try await request(
            "cron.manage",
            params: .object([
                "action": .string("list"),
                "include_disabled": .bool(true),
                "profile": .string(profile),
            ]),
            timeout: timeout)
        return CronJobList(
            jobs: result["jobs"]?.arrayValue?.compactMap(CronJob.init(json:)) ?? [],
            scopedToProfile: result["scoped"]?.stringValue == profile)
    }

    /// Pause or resume one cron job in the profile's store.
    public func setCronJobEnabled(
        jobID: String, enabled: Bool, profile: String, timeout: TimeInterval = 30
    ) async throws {
        _ = try await request(
            "cron.manage",
            params: .object([
                "action": .string(enabled ? "resume" : "pause"),
                "name": .string(jobID),
                "profile": .string(profile),
            ]),
            timeout: timeout)
    }

    /// Permanently remove one cron job from the profile's store.
    public func removeCronJob(
        jobID: String, profile: String, timeout: TimeInterval = 30
    ) async throws {
        _ = try await request(
            "cron.manage",
            params: .object([
                "action": .string("remove"),
                "name": .string(jobID),
                "profile": .string(profile),
            ]),
            timeout: timeout)
    }
}
