import Foundation
import Network
import Testing

/// The scripted server must answer each HTTP request exactly once. It used
/// to keep receiving after replying, and any later read — the client's
/// half-close, say — re-parsed the request still in the buffer and ran the
/// handler again, so tests counting REST hits saw doubles.
@Suite("HermesTestServer", .timeLimit(.minutes(1)))
struct HermesTestServerTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    @Test func aURLSessionGetRunsTheHandlerOnce() async throws {
        let hits = Counter()
        let server = try await HermesTestServer.start { request in
            if request.path == "/api/sessions/s1/messages" { hits.increment() }
            return TestHTTPResponse(200, #"{"messages": []}"#)
        }
        defer { server.stop() }

        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/api/sessions/s1/messages"))
        let (_, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        // Leave room for a stray second parse to land before counting.
        try await Task.sleep(for: .milliseconds(300))
        #expect(hits.count == 1)
    }

    /// A client that half-closes after its request makes the server's next
    /// receive report EOF — the read that used to re-run the handler.
    @Test(arguments: ["GET", "POST"])
    func aHalfClosedRequestRunsTheHandlerOnce(method: String) async throws {
        let hits = Counter()
        let server = try await HermesTestServer.start { _ in
            hits.increment()
            return TestHTTPResponse(200, "{}")
        }
        defer { server.stop() }

        let body = method == "POST" ? #"{"a": 1}"# : ""
        let request =
            "\(method) /api/thing HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let reply = try await Self.exchange(Data(request.utf8), port: server.port)
        #expect(String(decoding: reply, as: UTF8.self).hasPrefix("HTTP/1.1 200"))

        try await Task.sleep(for: .milliseconds(300))
        #expect(hits.count == 1)
    }

    /// Sends `request` then FIN, and collects the reply until the server closes.
    private static func exchange(_ request: Data, port: UInt16) async throws -> Data {
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        connection.start(queue: DispatchQueue(label: "test.hermes-client"))
        connection.send(content: request, isComplete: true, completion: .idempotent)
        return try await withCheckedThrowingContinuation { continuation in
            let collected = Collected()
            func next() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                    data, _, isComplete, error in
                    if let data { collected.data.append(data) }
                    if let error {
                        continuation.resume(throwing: error)
                    } else if isComplete {
                        continuation.resume(returning: collected.data)
                    } else {
                        next()
                    }
                }
            }
            next()
        }
    }

    private final class Collected: @unchecked Sendable {
        var data = Data()
    }
}
