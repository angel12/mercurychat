import Foundation
import MercuryKit
import Testing

/// The sidebar's Archive action soft-hides a stored session through the
/// fenced `PATCH /api/sessions/{id}`, and a refused pin or archive stays in
/// `browseError` — the refresh after an edit must not wipe it.
@Suite("Session edits", .timeLimit(.minutes(1)))
@MainActor
struct SessionEditTests {
    /// Lock-guarded record of the PATCH bodies the server received.
    final class Patches: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [JSONValue] = []
        func record(_ body: Data) {
            guard let json = try? JSONDecoder().decode(JSONValue.self, from: body) else { return }
            lock.withLock { bodies.append(json) }
        }
        var all: [JSONValue] { lock.withLock { bodies } }
    }

    private func connectedModel(
        patchStatus: Int, patches: Patches
    ) async throws -> (AppModel, () -> Void) {
        // A working projects.tree, so the post-edit refresh succeeds (and
        // would clear browseError if it ran after a refusal).
        let server = try await HermesTestServer.start(
            rpc: { method, _ in
                method == "projects.tree" ? .object(["projects": .array([])]) : nil
            }
        ) { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": false}"#)
            case ("GET", "/api/sessions/stored-a/mutation-snapshot"):
                return TestHTTPResponse(200, #"{"exists": true, "runtime_revision": 4}"#)
            case ("PATCH", "/api/sessions/stored-a"):
                patches.record(request.body)
                return patchStatus == 200
                    ? TestHTTPResponse(200)
                    : TestHTTPResponse(patchStatus, #"{"detail": "archive refused"}"#)
            default:
                return TestHTTPResponse(200, #"{"sessions": []}"#)
            }
        }
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let model = AppModel(tokenStore: store)
        await model.connect(endpoint: endpoint, credentials: nil)
        try #require(
            await eventually {
                if case .ready = model.phase { return true }
                return false
            })
        return (
            model,
            {
                model.disconnect()
                server.stop()
                try? store.deleteToken(for: endpoint)
            }
        )
    }

    private func session() throws -> SessionSummary {
        try #require(
            SessionSummary(
                json: .object(["session_id": .string("stored-a"), "profile": .string("work")])))
    }

    @Test func archiveSendsTheArchivedFlagForTheSessionsProfile() async throws {
        let patches = Patches()
        let (model, cleanup) = try await connectedModel(patchStatus: 200, patches: patches)
        defer { cleanup() }

        await model.archiveSession(try session())

        #expect(model.browseError == nil)
        let body = try #require(patches.all.first)
        #expect(body["archived"]?.boolValue == true)
        #expect(body["profile"]?.stringValue == "work")
        #expect(body["title"] == nil && body["pinned"] == nil)
    }

    @Test func aRefusedArchiveShowsInBrowseError() async throws {
        let patches = Patches()
        let (model, cleanup) = try await connectedModel(patchStatus: 500, patches: patches)
        defer { cleanup() }

        await model.archiveSession(try session())

        #expect(patches.all.count == 1)
        #expect(model.browseError != nil)
    }

    @Test func aRefusedPinShowsInBrowseError() async throws {
        let patches = Patches()
        let (model, cleanup) = try await connectedModel(patchStatus: 409, patches: patches)
        defer { cleanup() }

        await model.togglePin(try session())

        #expect(patches.all.first?["pinned"]?.boolValue == true)
        #expect(model.browseError != nil)
    }
}
