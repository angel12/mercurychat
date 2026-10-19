import Foundation
import MercuryKit
import Testing

/// Mercury Push session scope: a session counts as this device's when it was created here or a
/// message was sent from here, and the chat reports it (for a push claim) once its stored id is
/// known — a created session may learn that id only later, from `session.info`.
@Suite("Session activity")
struct SessionActivityTrackerTests {
    @Test func reportsAtOnceWhenTheStoredIDIsKnown() {
        var tracker = SessionActivityTracker()
        #expect(tracker.activity(storedID: "stored-1") == "stored-1")
        #expect(tracker.storedIDChanged("stored-2") == nil)  // nothing pending
    }

    @Test func holdsActivityUntilTheStoredIDArrives() {
        var tracker = SessionActivityTracker()
        #expect(tracker.activity(storedID: nil) == nil)
        #expect(tracker.storedIDChanged(nil) == nil)
        #expect(tracker.storedIDChanged("stored-1") == "stored-1")
        #expect(tracker.storedIDChanged("stored-1") == nil)  // reported once
    }
}

@Suite("Chat session activity", .timeLimit(.minutes(1)))
@MainActor
struct ChatSessionActivityTests {
    nonisolated static let title = "Activity"

    final class Recorder {
        var reports: [(storedID: String, profile: String?)] = []
    }

    /// `storedOnCreate`: whether `session.create` answers with a stored id.
    private func openChat(
        storedOnCreate: Bool, failSubmit: Bool = false
    ) async throws -> (ChatController, HermesTestServer, Recorder, () -> Void) {
        let server = try await HermesTestServer.start(
            rpc: { method, params in
                switch method {
                case "session.create" where params["title"]?.stringValue == Self.title:
                    return storedOnCreate
                        ? .object(["session_id": "rt-1", "stored_session_id": "stored-1"])
                        : .object(["session_id": "rt-1"])
                case "session.create":
                    return .object(["session_id": "rt-probe"])  // the contract probe
                case "prompt.submit":
                    return .object(["status": "streaming"])
                default:
                    return .object([:])
                }
            },
            rpcError: { method, _ in failSubmit && method == "prompt.submit" ? (-32000, "boom") : nil }
        ) { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": false}"#)
            default:
                return TestHTTPResponse(200, #"{"messages": []}"#)
            }
        }
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let model = AppModel(tokenStore: store)
        await model.connect(endpoint: endpoint, credentials: nil)
        // The gateway socket, not just REST: a create before `.ready` fails "not connected".
        try #require(
            await eventually {
                if case .ready = model.phase { return true }
                return false
            })
        let chat = try #require(model.openChat(profile: "coder"))
        let recorder = Recorder()
        chat.onSessionActivity = { storedID, profile in recorder.reports.append((storedID, profile)) }
        return (
            chat, server, recorder,
            {
                model.disconnect()
                server.stop()
                try? store.deleteToken(for: endpoint)
            }
        )
    }

    @Test func creatingASessionReportsIt() async throws {
        let (chat, _, recorder, cleanup) = try await openChat(storedOnCreate: true)
        defer { cleanup() }
        await chat.begin(.create(cwd: nil, title: Self.title))
        #expect(chat.errorMessage == nil)
        #expect(chat.runtimeID == "rt-1")
        #expect(recorder.reports.map(\.storedID) == ["stored-1"])
        #expect(recorder.reports.first?.profile == "coder")
        await chat.submit("hello")
        #expect(recorder.reports.map(\.storedID) == ["stored-1", "stored-1"])
    }

    @Test func aStoredIDLearnedLaterIsReportedWhenItArrives() async throws {
        let (chat, server, recorder, cleanup) = try await openChat(storedOnCreate: false)
        defer { cleanup() }
        await chat.begin(.create(cwd: nil, title: Self.title))
        await chat.submit("hello")
        #expect(recorder.reports.isEmpty)
        server.pushEvent("session.info", sessionID: "rt-1", payload: ["stored_session_id": "stored-1"])
        #expect(await eventually { recorder.reports.map(\.storedID) == ["stored-1"] })
    }

    @Test func aFailedSendReportsNothing() async throws {
        let (chat, _, recorder, cleanup) = try await openChat(storedOnCreate: true, failSubmit: true)
        defer { cleanup() }
        await chat.begin(.create(cwd: nil, title: Self.title))
        recorder.reports.removeAll()
        await chat.submit("hello")
        #expect(recorder.reports.isEmpty)
    }
}
