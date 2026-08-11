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
    public func submitPrompt(
        sessionID: String, text: String, interrupted: Bool = false
    ) async throws {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "text": .string(text),
        ]
        if interrupted { params["interrupted"] = .bool(true) }
        // Desktop uses a 30-minute timeout here.
        _ = try await request("prompt.submit", params: .object(params), timeout: 1800)
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

    // MARK: Projects

    /// `projects.tree` — the authoritative sidebar grouping (explicit
    /// projects, auto repo projects, `__no_project__` Home bucket).
    public func projectsTree(previewLimit: Int = 3) async throws -> ProjectTree {
        let result = try await request(
            "projects.tree", params: ["preview_limit": .number(Double(previewLimit))])
        return ProjectTree(json: result)
    }

    public func projectSessions(projectID: String) async throws -> [SessionSummary] {
        let result = try await request(
            "projects.project_sessions", params: ["project_id": .string(projectID)])
        return result["sessions"]?.arrayValue?.compactMap(SessionSummary.init(json:)) ?? []
    }

    // MARK: Prompt-family responses

    /// `approval.respond` — session-keyed (no request id); absent choice
    /// means deny server-side, so always pass one of the event's choices.
    public func respondApproval(sessionID: String, choice: String) async throws {
        _ = try await request(
            "approval.respond",
            params: ["session_id": .string(sessionID), "choice": .string(choice)])
    }

    /// `clarify.respond` — empty answer = skip. A late respond after expiry
    /// returns `{"status":"expired"}`, never an error.
    public func respondClarify(requestID: String, answer: String) async throws {
        _ = try await request(
            "clarify.respond",
            params: ["request_id": .string(requestID), "answer": .string(answer)])
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
    /// log or persist the value. Late answers return `{"status":"expired"}`.
    public func respondSudo(requestID: String, password: String) async throws {
        _ = try await request(
            "sudo.respond",
            params: ["request_id": .string(requestID), "password": .string(password)])
    }

    /// `secret.respond` — answer field is `value` (empty = skip). Never log
    /// or persist the value. Late answers return `{"status":"expired"}`.
    public func respondSecret(requestID: String, value: String) async throws {
        _ = try await request(
            "secret.respond",
            params: ["request_id": .string(requestID), "value": .string(value)])
    }
}
