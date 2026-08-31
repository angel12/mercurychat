import CryptoKit
import Foundation
import Network

/// The request/response pair for the scripted REST surface.
struct TestHTTPRequest: Sendable {
    var method: String
    var path: String
    /// Header names lowercased.
    var headers: [String: String]
    var body: Data
}

struct TestHTTPResponse: Sendable {
    var status: Int
    var body: String

    init(_ status: Int, _ body: String = "{}") {
        self.status = status
        self.body = body
    }
}

/// A fake Hermes server speaking scripted HTTP *and* WebSocket on ONE port —
/// AppModel probes and dials a single endpoint, so its tests must too. A
/// non-upgrade request is answered by the script and closed; an upgrade
/// request gets the RFC 6455 handshake plus an immediate `gateway.ready`
/// event, which is all GatewayClient needs to reach `.ready`. (Hand-rolled
/// like the package's TestServers: NWListener's own WebSocket options fail
/// with EINVAL on this macOS.)
final class HermesTestServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private let handler: @Sendable (TestHTTPRequest) -> TestHTTPResponse
    private var connections: [Connection] = []
    private(set) var port: UInt16 = 0

    static func start(
        handler: @escaping @Sendable (TestHTTPRequest) -> TestHTTPResponse
    ) async throws -> HermesTestServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let server = HermesTestServer(listener: listener, handler: handler)
        try await server.waitUntilReady()
        return server
    }

    private init(
        listener: NWListener,
        handler: @escaping @Sendable (TestHTTPRequest) -> TestHTTPResponse
    ) {
        self.listener = listener
        self.handler = handler
        // Installed BEFORE start(): a started NWListener without a
        // newConnectionHandler fails with EINVAL.
        listener.newConnectionHandler = { [weak self] nwConnection in
            guard let self else { return }
            let connection = Connection(nwConnection, handler: self.handler)
            self.lock.withLock { self.connections.append(connection) }
            connection.begin()
        }
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let box = ResumeOnce(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let self, let port = self.listener.port?.rawValue, port != 0 {
                        self.lock.withLock { self.port = port }
                        box.resume(.success(()))
                    } else {
                        box.resume(.failure(URLError(.cannotConnectToHost)))
                    }
                case .failed(let error):
                    box.resume(.failure(error))
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "test.hermes-server"))
        }
    }

    func stop() {
        lock.withLock {
            for connection in connections { connection.cancel() }
            connections = []
        }
        listener.cancel()
    }

    /// One accepted socket with its own buffer — HTTP requests arrive on
    /// fresh connections (responses are `Connection: close`), while an
    /// upgraded WebSocket stays open.
    private final class Connection: @unchecked Sendable {
        private let nwConnection: NWConnection
        private let handler: @Sendable (TestHTTPRequest) -> TestHTTPResponse
        private var buffer = Data()
        private var upgraded = false

        init(
            _ nwConnection: NWConnection,
            handler: @escaping @Sendable (TestHTTPRequest) -> TestHTTPResponse
        ) {
            self.nwConnection = nwConnection
            self.handler = handler
        }

        func begin() {
            nwConnection.start(queue: DispatchQueue(label: "test.hermes-connection"))
            receiveNext()
        }

        func cancel() {
            nwConnection.cancel()
        }

        private func receiveNext() {
            nwConnection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self] data, _, isComplete, error in
                guard let self, error == nil else { return }
                if let data { self.buffer.append(data) }
                if !self.upgraded { self.tryHandleHTTP(isComplete: isComplete) }
                // After the upgrade, inbound client frames (RPCs) are simply
                // ignored — nothing under test awaits their answers.
                if !isComplete { self.receiveNext() }
            }
        }

        private func tryHandleHTTP(isComplete: Bool) {
            guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { nwConnection.cancel() }
                return
            }
            guard let head = String(data: buffer[..<headEnd.lowerBound], encoding: .utf8)
            else {
                nwConnection.cancel()
                return
            }
            // Parse before the upgrade check: an upgrade request is scripted
            // like any other, so a test can refuse it.
            let lines = head.components(separatedBy: "\r\n")
            let requestParts = (lines.first ?? "").components(separatedBy: " ")
            guard requestParts.count >= 2 else {
                nwConnection.cancel()
                return
            }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
            let body = buffer[headEnd.upperBound...]
            guard body.count >= contentLength else { return }

            // Strip any query string — the scripts match bare paths.
            let path = requestParts[1].components(separatedBy: "?")[0]
            let response = handler(
                TestHTTPRequest(
                    method: requestParts[0],
                    path: path,
                    headers: headers,
                    body: Data(body.prefix(contentLength))))

            if head.lowercased().contains("upgrade: websocket") {
                // Only an explicit 401 refuses the upgrade: GatewayClient
                // maps that onto the "(4401)" credential rejection, which is
                // what stops a redial storm and demands re-auth. Every other
                // status upgrades, so scripts that answer unlisted paths with
                // a catch-all 404 keep working unchanged.
                if response.status != 401 {
                    upgraded = true
                    buffer.removeSubrange(..<headEnd.upperBound)
                    nwConnection.send(
                        content: Self.handshakeResponse(head: head),
                        isComplete: true, completion: .idempotent)
                    sendText(
                        #"{"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {}}}"#
                    )
                    return
                }
            }

            let reason = response.status == 200 ? "OK" : "Error"
            let text =
                "HTTP/1.1 \(response.status) \(reason)\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(response.body.utf8.count)\r\n"
                + "Connection: close\r\n\r\n\(response.body)"
            nwConnection.send(
                content: Data(text.utf8), isComplete: true,
                completion: .contentProcessed { [weak self] _ in
                    self?.nwConnection.cancel()
                })
        }

        private static func handshakeResponse(head: String) -> Data {
            let key =
                head.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
                .split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let accept = Data(
                Insecure.SHA1.hash(
                    data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
            ).base64EncodedString()
            return Data(
                ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                    + "Connection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n").utf8)
        }

        /// Send one unmasked server→client text frame (payloads here are
        /// always tiny).
        private func sendText(_ text: String) {
            let payload = Data(text.utf8)
            var frame = Data([0x81])
            if payload.count < 126 {
                frame.append(UInt8(payload.count))
            } else {
                frame.append(126)
                frame.append(UInt8(payload.count >> 8))
                frame.append(UInt8(payload.count & 0xFF))
            }
            frame.append(payload)
            nwConnection.send(content: frame, isComplete: true, completion: .idempotent)
        }
    }
}

/// Continuation guard: listener state handlers can fire more than once.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        let taken = lock.withLock {
            let taken = continuation
            continuation = nil
            return taken
        }
        taken?.resume(with: result)
    }
}

// MARK: Shared polling helpers

/// Poll until `condition` holds. Socket callbacks land on background queues
/// and the update pump hops back to the MainActor, so state a test is waiting
/// on becomes true a few hops after the call that caused it.
@MainActor
func eventually(
    within seconds: TimeInterval = 10, _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A one-shot cross-thread flag. The scripted server runs its handler on its
/// own queue, so a test that needs to act *while* a request is in flight has
/// to learn that it landed from off the MainActor.
final class TestLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false

    func signal() {
        lock.lock()
        signalled = true
        lock.unlock()
    }

    private var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signalled
    }

    func wait(within seconds: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isSet { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isSet
    }
}
