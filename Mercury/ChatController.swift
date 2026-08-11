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
                // that is exactly why omit_messages exists.
                async let hydration = try? connection.rest.sessionMessages(
                    storedID: session.storedID, limit: Self.pageSize, profile: profile)
                let handle = try await connection.resumeSession(
                    storedID: session.storedID, profile: profile)
                adopt(handle)
                if let page = await hydration {
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
    private func applyResumeExtras(_ result: JSONValue) {
        store.setRunning(result["running"]?.truthy ?? false)
        if let inflight = result["inflight"], inflight.objectValue != nil {
            store.restoreInflight(
                user: inflight["user"]?.stringValue ?? "",
                corrections: inflight["corrections"]?.arrayValue?
                    .compactMap(\.stringValue) ?? [],
                assistant: inflight["assistant"]?.stringValue ?? "",
                streaming: inflight["streaming"]?.truthy ?? false,
                error: inflight["error"]?.stringValue)
        }
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

    func respondApproval(choice: String) async {
        guard let runtimeID else { return }
        try? await connection.respondApproval(sessionID: runtimeID, choice: choice)
        store.clearApproval()
    }

    func respondClarify(requestID: String, answer: String) async {
        try? await connection.respondClarify(requestID: requestID, answer: answer)
        store.clearClarify()
    }

    func respondSudo(requestID: String, password: String) async {
        try? await connection.respondSudo(requestID: requestID, password: password)
        store.clearSudo()
    }

    func respondSecret(requestID: String, value: String) async {
        try? await connection.respondSecret(requestID: requestID, value: value)
        store.clearSecret()
    }
}
