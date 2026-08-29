import Foundation
import os

/// Outcome of `session.close`. The server replies `{"closed": true}` when the
/// runtime session actually shut down; anything else means it may still be
/// holding resources (sockets, profile DB handles) on the backend.
public enum SessionCloseOutcome: Sendable, Equatable {
    /// Server confirmed `closed: true`.
    case closed
    /// RPC succeeded but the server did not confirm (`closed` missing/false).
    case unconfirmed
    /// The request itself failed (transport error, timeout, not connected).
    case failed(String)
}

/// Result of `image.attach_bytes`: where the gateway staged the image.
public struct ImageAttachment: Sendable, Equatable {
    /// Gateway-side staging path — the `image.detach` key.
    public var path: String
    /// How many images are now staged on the session.
    public var count: Int?

    public init(path: String, count: Int? = nil) {
        self.path = path
        self.count = count
    }
}

/// Typed wrappers over the gateway RPC methods the app uses.
extension HermesConnection {
    /// Column count reported to the backend; matches the desktop client.
    private static let cols = 96
    private static let source = "desktop"
    private static let logger = Logger(subsystem: "Mercury", category: "MercuryKit")

    /// os_log serializes each message into a ~1 KB buffer; anything larger is
    /// truncated at emission and renders as "<decode: bad range>" — the payload
    /// is lost everywhere, including Console.app. Clamp diagnostic dumps well
    /// under the limit so the interesting prefix always survives.
    private static func clampForLog(_ s: String, max: Int = 800) -> String {
        s.count <= max ? s : "\(s.prefix(max))… [\(s.count - max) more chars truncated]"
    }

    // MARK: Sessions

    /// `session.create` — `cwd` binds the session to a project directory;
    /// omit for "no workspace". The DB row appears lazily on first prompt.
    public func createSession(
        cwd: String? = nil, profile: String? = nil, title: String? = nil
    ) async throws -> SessionHandle {
        var params: [String: JSONValue] = [
            "cols": .number(Double(Self.cols)),
            "source": .string(Self.source),
        ]
        if let cwd, !cwd.isEmpty { params["cwd"] = .string(cwd) }
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        if let title, !title.isEmpty { params["title"] = .string(title) }

        let result = try await request("session.create", params: .object(params))
        guard let handle = SessionHandle(result: result) else {
            throw HermesError.malformedResponse("session.create returned no session_id")
        }
        return handle
    }

    /// `session.resume` by **stored** id. Pass the session's owning profile —
    /// cross-profile resume opens that profile's state DB. The result's
    /// `resumed` field may differ from the requested id (compression
    /// continuation chains are followed to the live tip); the returned
    /// handle's `storedID` is re-anchored to it.
    public func resumeSession(
        storedID: String, profile: String? = nil
    ) async throws -> SessionHandle {
        var params: [String: JSONValue] = [
            "session_id": .string(storedID),
            "cols": .number(Double(Self.cols)),
            "source": .string(Self.source),
            "omit_messages": .bool(true),
        ]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }

        let result = try await request("session.resume", params: .object(params), timeout: 120)
        guard var handle = SessionHandle(result: result) else {
            throw HermesError.malformedResponse("session.resume returned no session_id")
        }
        // resume names the durable id `session_key`/`resumed`, not
        // `stored_session_id`.
        handle.storedID =
            result["resumed"]?.stringValue
            ?? result["session_key"]?.stringValue
            ?? handle.storedID
            ?? storedID
        return handle
    }

    /// `prompt.submit` returns `{"status":"streaming"}` immediately — the
    /// reply arrives only via events; never await this for completion. Set
    /// `interrupted` on the first submit after a barge-in so the backend
    /// prepends a "your spoken reply was cut off" note for the model.
    /// Returns the server's dispatch status: `"streaming"` (turn started),
    /// or — when submitted mid-turn — `"queued"`, `"redirected"`, or
    /// `"steered"` per the server's busy-input policy. Nil when the result
    /// carries no status (older backends).
    @discardableResult
    public func submitPrompt(
        sessionID: String, text: String, interrupted: Bool = false
    ) async throws -> String? {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "text": .string(text),
        ]
        if interrupted { params["interrupted"] = .bool(true) }
        // Desktop uses a 30-minute timeout here.
        let result = try await request("prompt.submit", params: .object(params), timeout: 1800)
        return result["status"]?.stringValue
    }

    // MARK: Attachments

    /// `image.attach_bytes` — stage an image into session state; the NEXT
    /// `prompt.submit` consumes everything staged. `path` is the gateway-side
    /// staging path and the `image.detach` key. Base64 payloads can be tens of
    /// MB, hence the long timeout. Never log the payload.
    public func attachImageBytes(
        sessionID: String, base64: String, filename: String? = nil
    ) async throws -> ImageAttachment {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "content_base64": .string(base64),
        ]
        if let filename, !filename.isEmpty { params["filename"] = .string(filename) }
        let result = try await request(
            "image.attach_bytes", params: .object(params), timeout: 300)
        guard result["attached"]?.truthy == true,
            let path = result["path"]?.stringValue
        else {
            throw HermesError.malformedResponse("image.attach_bytes did not confirm attachment")
        }
        return ImageAttachment(path: path, count: result["count"]?.intValue)
    }

    /// `image.detach` — unstage one attached image. Called on failed sends so
    /// an orphaned staged image isn't silently consumed by the next prompt.
    public func detachImage(sessionID: String, path: String) async throws {
        _ = try await request(
            "image.detach",
            params: ["session_id": .string(sessionID), "path": .string(path)])
    }

    /// Cancel the in-flight turn (used on barge-in while still generating).
    public func interruptSession(sessionID: String) async throws {
        _ = try await request("session.interrupt", params: ["session_id": .string(sessionID)])
    }

    /// Detach politely when leaving a session, verifying the server's answer:
    /// an unconfirmed or failed close means the backend may still hold the
    /// session's sockets and profile DB handles. Every outcome is logged so
    /// leak investigations don't have to guess whether End reached the server.
    @discardableResult
    public func closeSession(sessionID: String) async -> SessionCloseOutcome {
        do {
            let result = try await request(
                "session.close", params: ["session_id": .string(sessionID)])
            if result["closed"]?.truthy == true {
                Self.logger.info(
                    "session.close confirmed for \(sessionID, privacy: .public)")
                return .closed
            }
            Self.logger.error(
                "session.close NOT confirmed for \(sessionID, privacy: .public): \(Self.clampForLog("\(result)"), privacy: .public)"
            )
            return .unconfirmed
        } catch {
            let reason = (error as? HermesError)?.errorDescription ?? "\(error)"
            Self.logger.error(
                "session.close failed for \(sessionID, privacy: .public): \(Self.clampForLog(reason), privacy: .public)"
            )
            return .failed(reason)
        }
    }

    /// Probe the backend's `desktop_contract`. The gateway advertises it only
    /// in session-info shapes (`gateway.ready` carries no such field), so the
    /// cheapest read is a throwaway lazy session — no DB row until first
    /// prompt — created and closed immediately.
    ///
    /// The close is guaranteed (issue #49): it runs in an unstructured task so
    /// caller cancellation between create and close can't strand a live
    /// runtime session — a ghost in `session.list` and every client's sidebar
    /// — and an unconfirmed/failed close is retried once. `closeSession`
    /// already logs every outcome for leak investigations.
    ///
    /// Returns nil when the backend predates the field. Throws only when the
    /// create itself fails (then there is nothing to clean up).
    public func probeDesktopContract() async throws -> Int? {
        let handle = try await createSession()
        let sessionID = handle.runtimeID
        let close = Task {
            var outcome = await self.closeSession(sessionID: sessionID)
            if outcome != .closed {
                outcome = await self.closeSession(sessionID: sessionID)
            }
            return outcome
        }
        // Await it (an unstructured task ignores the caller's cancellation)
        // so the probe never resolves while its cleanup is still in flight.
        _ = await close.value
        return handle.desktopContract
    }

    // MARK: Projects

    /// `projects.tree` — the authoritative sidebar grouping (explicit
    /// projects, auto repo projects, `__no_project__` Home bucket). Pass the
    /// selected `profile` — the RPC is profile-scoped and defaults to the
    /// gateway's launch profile when the param is omitted.
    public func projectsTree(
        previewLimit: Int = 3, profile: String? = nil
    ) async throws -> ProjectTree {
        var params: [String: JSONValue] = [
            "preview_limit": .number(Double(previewLimit))
        ]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await request("projects.tree", params: .object(params))
        return ProjectTree(json: result)
    }

    public func projectSessions(
        projectID: String, profile: String? = nil
    ) async throws -> [SessionSummary] {
        var params: [String: JSONValue] = ["project_id": .string(projectID)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await request("projects.project_sessions", params: .object(params))
        return result["sessions"]?.arrayValue?.compactMap(SessionSummary.init(json:)) ?? []
    }

    // MARK: Prompt-family responses

    /// `approval.respond` — absent choice means deny server-side, so always
    /// pass one of the event's choices. Without `requestID` the server
    /// resolves the OLDEST queued approval; pass the event's id when it has
    /// one so the answer lands on the exact card the user saw.
    public func respondApproval(
        sessionID: String, choice: String, requestID: String? = nil
    ) async throws {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID), "choice": .string(choice),
        ]
        if let requestID, !requestID.isEmpty { params["request_id"] = .string(requestID) }
        _ = try await request("approval.respond", params: .object(params))
    }

    /// `clarify.respond` — empty answer = skip. A late respond after expiry
    /// returns `{"status":"expired"}`, never an error — a successful
    /// transport call is NOT delivery; check the returned status.
    ///
    /// On a BATCH clarify, calling this without a question id cancels the
    /// whole batch (server resolves every question with this one answer).
    public func respondClarify(
        requestID: String, answer: String
    ) async throws -> PromptResponseStatus {
        let result = try await request(
            "clarify.respond",
            params: ["request_id": .string(requestID), "answer": .string(answer)])
        return try PromptResponseStatus(result: result)
    }

    /// Answer ONE question of a batch clarify. Returns the qids still
    /// unanswered (nil when the request had already expired); the batch
    /// resolves server-side when the list empties. A locked answer stays
    /// editable until then — re-responding the same qid overwrites it.
    public func respondClarifyQuestion(
        requestID: String, questionID: String, answer: String
    ) async throws -> [String]? {
        let result = try await request(
            "clarify.respond",
            params: [
                "request_id": .string(requestID),
                "question_id": .string(questionID),
                "answer": .string(answer),
            ])
        if case .expired = try PromptResponseStatus(result: result) { return nil }
        return result["remaining"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

/// Outcome of answering a blocking prompt (clarify / sudo / secret). The
/// server resolves a late answer with `{"status": "expired"}` instead of an
/// error, so transport success alone must never be treated as delivery.
public enum PromptResponseStatus: Sendable, Equatable {
    /// The answer reached the waiting agent.
    case accepted
    /// The request had already expired server-side — the answer was
    /// discarded and the agent never saw it.
    case expired

    init(result: JSONValue) throws {
        switch result["status"]?.stringValue {
        case "ok": self = .accepted
        case "expired": self = .expired
        case let other:
            throw HermesError.malformedResponse(
                "respond returned unrecognized status \(other ?? "<missing>")")
        }
    }
}

// MARK: - Session management + mid-turn controls

extension HermesConnection {
    /// `session.steer` — inject text into the next tool result of the
    /// running turn without interrupting. Returns true when the agent
    /// accepted it (`status: "queued"`).
    @discardableResult
    public func steerSession(sessionID: String, text: String) async throws -> Bool {
        let result = try await request(
            "session.steer",
            params: ["session_id": .string(sessionID), "text": .string(text)])
        return result["status"]?.stringValue == "queued"
    }

    /// `session.redirect` — redirect the active model turn, preserving valid
    /// work. Falls back server-side to queueing during the turn-build window.
    @discardableResult
    public func redirectSession(sessionID: String, text: String) async throws -> Bool {
        let result = try await request(
            "session.redirect",
            params: ["session_id": .string(sessionID), "text": .string(text)])
        return result["status"]?.stringValue == "queued"
    }

    /// `session.title` — set (or, with nil, fetch/settle) the session title.
    /// Returns the resolved title.
    @discardableResult
    public func setSessionTitle(sessionID: String, title: String?) async throws -> String? {
        var params: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let title { params["title"] = .string(title) }
        let result = try await request("session.title", params: .object(params))
        return result["title"]?.stringValue
    }

    /// `session.delete` — delete a **stored** session and its transcript
    /// files. The server refuses to delete a session live in this gateway.
    public func deleteSession(storedID: String, profile: String? = nil) async throws {
        var params: [String: JSONValue] = ["session_id": .string(storedID)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        _ = try await request("session.delete", params: .object(params))
    }

    /// One page of the gateway's reconnect replay ring (v0.20.5+).
    public struct EventReplayPage: Sendable {
        /// The missed events, oldest first, ready for normal dispatch.
        public var events: [GatewayEvent]
        public var latestSeq: Int?
        /// True when the ring evicted part of the gap — the replay is
        /// incomplete and the caller must fall back to full re-hydration.
        public var truncated: Bool
        /// Process identity of the seq numbering; a change means the gateway
        /// restarted and every watermark is void.
        public var epoch: String?
    }

    /// `session.events.since` — replay session events newer than `lastSeen`
    /// after a reconnect (the server buffers the last 512 per session, even
    /// while the socket is down). Throws -32601 on pre-0.20.5 backends.
    public func sessionEventsSince(
        sessionID: String, lastSeen: Int
    ) async throws -> EventReplayPage {
        let result = try await request(
            "session.events.since",
            params: [
                "session_id": .string(sessionID),
                "last_seen": .number(Double(lastSeen)),
            ])
        let events = result["events"]?.arrayValue?.compactMap { frame -> GatewayEvent? in
            guard let type = frame["type"]?.stringValue else { return nil }
            return GatewayEvent(
                type: type,
                sessionID: frame["session_id"]?.stringValue,
                payload: frame["payload"] ?? .null,
                seq: frame["seq"]?.intValue)
        }
        return EventReplayPage(
            events: events ?? [],
            latestSeq: result["latest_seq"]?.intValue,
            truncated: result["truncated"]?.truthy ?? true,
            epoch: result["epoch"]?.stringValue)
    }

    /// `session.branch` — fork the session's history into a new session.
    /// `count` limits how many history messages carry over. Returns the new
    /// session's handle when the result carries one.
    public func branchSession(
        sessionID: String, name: String? = nil, count: Int? = nil
    ) async throws -> SessionHandle? {
        var params: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let name, !name.isEmpty { params["name"] = .string(name) }
        if let count, count > 0 { params["count"] = .number(Double(count)) }
        let result = try await request("session.branch", params: .object(params), timeout: 120)
        return SessionHandle(result: result)
    }

    /// `model.options` — populate a model picker. The payload shape is
    /// provider-grouped; flatten to options where recognizable.
    public func modelOptions(sessionID: String? = nil) async throws -> JSONValue {
        var params: [String: JSONValue] = [:]
        if let sessionID { params["session_id"] = .string(sessionID) }
        return try await request(
            "model.options", params: params.isEmpty ? nil : .object(params), timeout: 120)
    }

    // MARK: Secure blocking-prompt responses

    /// `sudo.respond` — answer field is `password` (empty = decline). Never
    /// log or persist the value. Late answers return `{"status":"expired"}`;
    /// check the returned status before reporting delivery.
    public func respondSudo(
        requestID: String, password: String
    ) async throws -> PromptResponseStatus {
        let result = try await request(
            "sudo.respond",
            params: ["request_id": .string(requestID), "password": .string(password)])
        return try PromptResponseStatus(result: result)
    }

    /// `secret.respond` — answer field is `value` (empty = skip). Never log
    /// or persist the value. Late answers return `{"status":"expired"}`;
    /// check the returned status before reporting delivery.
    public func respondSecret(
        requestID: String, value: String
    ) async throws -> PromptResponseStatus {
        let result = try await request(
            "secret.respond",
            params: ["request_id": .string(requestID), "value": .string(value)])
        return try PromptResponseStatus(result: result)
    }

    /// `mcp.setup.respond` — answer field is `result`, a JSON **string** of
    /// the setup card's outcome. `status` must be one of installed | enabled
    /// | authorized | declined | error; on declined the agent continues
    /// without the server and must not re-ask.
    public func respondMcpSetup(
        requestID: String, status: String, server: String, detail: String? = nil
    ) async throws -> PromptResponseStatus {
        var outcome: [String: JSONValue] = [
            "status": .string(status), "server": .string(server),
        ]
        if let detail, !detail.isEmpty { outcome["detail"] = .string(detail) }
        let result = try await request(
            "mcp.setup.respond",
            params: [
                "request_id": .string(requestID),
                "result": .string(JSONValue.object(outcome).encodedString()),
            ])
        return try PromptResponseStatus(result: result)
    }
}
