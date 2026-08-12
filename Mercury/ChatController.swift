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

    private let connection: HermesConnection
    private let profile: String?
    private static let logger = Logger(subsystem: "Mercury", category: "ChatController")
    /// Older-history paging state (order=latest offsets count back from the
    /// newest row).
    private var loadedOffset = 0
    private static let pageSize = 100

    init(connection: HermesConnection, profile: String?) {
        self.connection = connection
        self.profile = profile
    }

    // MARK: Lifecycle

    func begin(_ mode: Mode) async {
        isLoading = true
        defer { isLoading = false }
        do {
            switch mode {
            case .create(let cwd, let title):
                let handle = try await connection.createSession(
                    cwd: cwd, profile: profile, title: title)
                adopt(handle)

            case .resume(let session):
                let profile = session.profile ?? self.profile
                // Resume (omit_messages) and REST hydration run in parallel —
                // that is exactly why omit_messages exists. `order` must be
                // explicit: with a limit but no order the server anchors at
                // the OLDEST rows.
                async let hydration = try? connection.rest.sessionMessages(
                    storedID: session.storedID, limit: Self.pageSize, order: "latest",
                    profile: profile)
                let handle = try await connection.resumeSession(
                    storedID: session.storedID, profile: profile)
                adopt(handle)
                var page = await hydration
                // Resume can re-anchor to a continuation session's durable
                // id (context-compression chains). A page fetched for the
                // requested id would splice the wrong session's history and
                // leave paging offsets pointing into it — refetch by the id
                // resume actually returned.
                if let reanchored = handle.storedID, reanchored != session.storedID {
                    page = try? await connection.rest.sessionMessages(
                        storedID: reanchored, limit: Self.pageSize, order: "latest",
                        profile: profile)
                }
                if let page {
                    store.hydrate(page.messages)
                    loadedOffset = page.messages.count
                    canLoadOlder = page.returned == (page.limit ?? Self.pageSize)
                }
                applyResumeExtras(handle.raw)
            }
        } catch let error as HermesError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func adopt(_ handle: SessionHandle) {
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
        store.setRunning(result["running"]?.truthy ?? false)
    }

    /// The socket came back after a drop: runtime ids may be recycled, so
    /// re-resume by **stored** id and re-hydrate.
    func connectionBecameReady(isReconnect: Bool) async {
        guard isReconnect, let storedID else { return }
        Self.logger.info("re-resuming \(storedID, privacy: .public) after reconnect")
        await begin(.resume(sessionSummaryForResume(storedID: storedID)))
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
    func handle(event: GatewayEvent) {
        guard let runtimeID else { return }
        guard event.sessionID == nil || event.sessionID == runtimeID else { return }
        store.apply(event)
        // A session.title event may also rename; keep the stored id fresh
        // if the server re-anchors it.
        if event.type == GatewayEvent.Kind.sessionInfo,
            let stored = event.payload["stored_session_id"]?.stringValue, !stored.isEmpty
        {
            storedID = stored
        }
    }

    // MARK: Actions

    func submit(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let runtimeID else { return }
        store.appendUserMessage(trimmed)
        do {
            // Submitting while busy queues server-side rather than erroring.
            try await connection.submitPrompt(sessionID: runtimeID, text: trimmed)
            // The DB row exists after the first prompt; a created session
            // learns its stored id via session.info events.
        } catch let error as HermesError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func interrupt() async {
        guard let runtimeID else { return }
        try? await connection.interruptSession(sessionID: runtimeID)
    }

    func loadOlderMessages() async {
        guard canLoadOlder, let storedID, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard
            let page = try? await connection.rest.sessionMessages(
                storedID: storedID, limit: Self.pageSize, offset: loadedOffset,
                order: "latest", profile: profile)
        else { return }
        store.prependOlder(page.messages)
        loadedOffset += page.messages.count
        canLoadOlder = !page.messages.isEmpty && page.returned == (page.limit ?? Self.pageSize)
    }

    func rename(_ title: String) async {
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
            try await connection.respondApproval(sessionID: runtimeID, choice: choice)
            store.clearApproval(matching: request)
            return true
        } catch {
            errorMessage = describe(error)
            return false
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
            errorMessage = describe(error)
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
            errorMessage = describe(error)
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
            errorMessage = describe(error)
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

    private func describe(_ error: Error) -> String {
        (error as? HermesError)?.errorDescription ?? error.localizedDescription
    }
}
