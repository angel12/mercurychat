import ChatCore
import Foundation
import MercuryKit
import Testing

/// Issue #96: `loadOlderMessages` captured neither the begin generation nor
/// the stored id it was paging, and cleared `isLoading` unconditionally. A
/// resume that re-anchors to a continuation session (reconnect, compression)
/// while an older page is in flight then let that late page write into the
/// new session — prepending the old session's rows, inflating the paging
/// offset, overwriting `canLoadOlder` — and clear the new resume's loading
/// state. These hold the older page and release it around the new resume.
@Suite("Older page generation", .timeLimit(.minutes(1)))
@MainActor
struct OlderPageGenerationTests {
    /// One held HTTP response. Each REST request is its own connection, so
    /// blocking the handler holds only that request.
    final class Hold: @unchecked Sendable {
        let reached = TestLatch()
        private let released = DispatchSemaphore(value: 0)
        func release() { released.signal() }
        func wait() {
            reached.signal()
            _ = released.wait(timeout: .now() + 10)
        }
    }

    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var resumedStoredID = "stored-1"
        private var paths: [String] = []
        let olderPage = Hold()
        let continuationPage = Hold()
        private var holdContinuation = false

        func reanchor(holdingItsHistory hold: Bool) {
            lock.withLock {
                resumedStoredID = "stored-2"
                holdContinuation = hold
            }
        }
        var requestedPaths: [String] { lock.withLock { paths } }

        func resume() -> JSONValue {
            lock.withLock {
                [
                    "session_id": "rt-1", "stored_session_id": .string(resumedStoredID),
                    "info": ["desktop_contract": 8],
                ]
            }
        }

        func http(_ request: TestHTTPRequest) -> TestHTTPResponse {
            lock.withLock { paths.append(request.path + "?" + request.query) }
            if request.path == "/api/status" {
                return TestHTTPResponse(200, #"{"auth_required": false}"#)
            }
            // The client omits `offset` for the first (latest) page.
            let isOlderPage = request.query.contains("offset=")
            if request.path.hasPrefix("/api/sessions/stored-1/messages") {
                if !isOlderPage { return Self.page(prefix: "first", count: 100) }
                olderPage.wait()
                return Self.page(prefix: "stale older", count: 5)
            }
            if request.path.hasPrefix("/api/sessions/stored-2/messages") {
                if lock.withLock({ holdContinuation }) { continuationPage.wait() }
                return Self.page(prefix: "continuation", count: 100)
            }
            return TestHTTPResponse(200, "{}")
        }

        /// A page of `count` rows; a full page (100) means more are older.
        static func page(prefix: String, count: Int) -> TestHTTPResponse {
            let rows = (0..<count).map { index -> JSONValue in
                [
                    "id": .number(Double(prefix.hashValue & 0xFFFF) * 1000 + Double(index)),
                    "role": index.isMultiple(of: 2) ? "user" : "assistant",
                    "content": .string("\(prefix) \(index)"),
                ]
            }
            let body: JSONValue = [
                "messages": .array(rows),
                "pagination": ["limit": 100, "offset": 0, "returned": .number(Double(count))],
            ]
            let data = (try? JSONEncoder().encode(body)) ?? Data()
            return TestHTTPResponse(200, String(decoding: data, as: UTF8.self))
        }
    }

    /// Resume "stored-1" (a full first page, so older pages exist) and start
    /// an older-page fetch that the server holds.
    private func pagingChat() async throws -> (ChatController, Script, Task<Void, Never>, () -> Void) {
        let script = Script()
        let server = try await HermesTestServer.start(
            rpc: { method, _ in
                switch method {
                case "session.resume": return script.resume()
                case "session.create": return ["session_id": "rt-probe", "info": ["desktop_contract": 8]]
                default: return .object([:])
                }
            }
        ) { request in script.http(request) }
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let model = AppModel(tokenStore: store)
        let cleanup = {
            script.olderPage.release()
            script.continuationPage.release()
            model.disconnect()
            server.stop()
            try? store.deleteToken(for: endpoint)
        }
        await model.connect(endpoint: endpoint, credentials: nil)
        let ready = await eventually {
            if case .ready = model.phase { return true }
            return false
        }
        try #require(ready)

        let chat = try #require(model.openChat(profile: nil))
        await chat.begin(.resume(try #require(SessionSummary(json: ["id": "stored-1"]))))
        try #require(chat.canLoadOlder)
        let loadingOlder = Task { await chat.loadOlderMessages() }
        #expect(await script.olderPage.reached.wait(), "the older page was never requested")
        return (chat, script, loadingOlder, cleanup)
    }

    private func texts(_ chat: ChatController) -> [String] {
        chat.store.items.compactMap { item in
            switch item {
            case .user(let message): return message.text
            case .assistant(let message): return message.text
            default: return nil
            }
        }
    }

    /// The stale page lands while the new resume is still loading its
    /// history: its cleanup must not clear the new resume's loading state.
    @Test func aStaleOlderPageLeavesTheNewResumeLoading() async throws {
        let (chat, script, loadingOlder, cleanup) = try await pagingChat()
        defer { cleanup() }

        script.reanchor(holdingItsHistory: true)
        let resuming = Task {
            await chat.begin(.resume(SessionSummary(json: ["id": "stored-1"])!))
        }
        #expect(await script.continuationPage.reached.wait(), "the continuation page was never requested")
        #expect(chat.isLoading)

        script.olderPage.release()
        await loadingOlder.value
        #expect(chat.isLoading, "the stale older page cleared the new resume's loading state")

        script.continuationPage.release()
        await resuming.value
        #expect(!chat.isLoading)
    }

    /// The stale page lands after the new resume has hydrated the
    /// continuation: none of it may reach the new session.
    @Test func aStaleOlderPageNeverWritesIntoTheContinuation() async throws {
        let (chat, script, loadingOlder, cleanup) = try await pagingChat()
        defer { cleanup() }

        script.reanchor(holdingItsHistory: false)
        await chat.begin(.resume(SessionSummary(json: ["id": "stored-1"])!))
        #expect(texts(chat).first == "continuation 0")

        script.olderPage.release()
        await loadingOlder.value

        #expect(!texts(chat).contains { $0.hasPrefix("stale older") }, "stale rows were prepended")
        #expect(texts(chat).count == 100)
        #expect(chat.canLoadOlder, "the stale short page cleared canLoadOlder")
        #expect(!chat.isLoading)

        // Paging continues from the continuation's own offset, not one the
        // stale page inflated.
        let before = script.requestedPaths.count
        let nextPage = Task { await chat.loadOlderMessages() }
        let requested = await eventually {
            script.requestedPaths.dropFirst(before).contains { $0.hasPrefix("/api/sessions/stored-2/messages") }
        }
        #expect(requested)
        let olderRequest = script.requestedPaths.dropFirst(before)
            .first { $0.hasPrefix("/api/sessions/stored-2/messages") }
        #expect(olderRequest?.contains("offset=100") == true, "requested: \(olderRequest ?? "none")")
        await nextPage.value
    }
}
