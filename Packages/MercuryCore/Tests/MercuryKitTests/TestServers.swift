import CryptoKit
import Foundation
import Network

/// Local test servers: a scripted WebSocket gateway and a scripted HTTP
/// endpoint, both on 127.0.0.1 with OS-assigned ports, so GatewayClient and
/// HermesAuthenticator are exercised over real sockets — the same house
/// style as the loopback PKCE listener tests.

// MARK: - WebSocket gateway

/// Minimal RFC 6455 server over a plain TCP NWListener. (NWListener with
/// NWProtocolWebSocket options fails to start with EINVAL on this macOS, so
/// the handshake and framing are done by hand — ~100 lines, and it keeps the
/// server behavior fully scriptable.)
final class LocalGatewayServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var connection: NWConnection?
    private var handshaken = false
    private var pending: [UInt8] = []
    private let onOpen: @Sendable (LocalGatewayServer) -> Void
    private let onText: @Sendable (String, LocalGatewayServer) -> Void
    private(set) var port: UInt16 = 0

    /// Frames received from the client, in arrival order.
    var receivedFrames: [String] {
        lock.withLock { frames }
    }
    private var frames: [String] = []

    static func start(
        onOpen: @escaping @Sendable (LocalGatewayServer) -> Void = { server in
            server.sendEvent(type: "gateway.ready")
        },
        onText: @escaping @Sendable (String, LocalGatewayServer) -> Void = { _, _ in }
    ) async throws -> LocalGatewayServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let server = LocalGatewayServer(listener: listener, onOpen: onOpen, onText: onText)
        try await server.waitUntilReady()
        return server
    }

    private init(
        listener: NWListener,
        onOpen: @escaping @Sendable (LocalGatewayServer) -> Void,
        onText: @escaping @Sendable (String, LocalGatewayServer) -> Void
    ) {
        self.listener = listener
        self.onOpen = onOpen
        self.onText = onText
        // The handler must be installed BEFORE start(): a started NWListener
        // without a newConnectionHandler fails with EINVAL.
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.connection = connection }
            connection.start(queue: DispatchQueue(label: "test.gateway-connection"))
            self.receiveNext(connection)
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
            listener.start(queue: DispatchQueue(label: "test.gateway-server"))
        }
    }

    private func receiveNext(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data {
                self.lock.withLock { self.pending.append(contentsOf: data) }
                self.drainBuffer(connection)
            }
            self.receiveNext(connection)
        }
    }

    private func drainBuffer(_ connection: NWConnection) {
        let needsHandshake = lock.withLock { !handshaken }
        if needsHandshake {
            guard let response = lock.withLock({ takeHandshakeLocked() }) else { return }
            connection.send(
                content: response, isComplete: true, completion: .idempotent)
            onOpen(self)
        }
        for (opcode, payload) in lock.withLock({ parseFramesLocked() }) {
            if opcode == 0x1, let text = String(data: payload, encoding: .utf8) {
                lock.withLock { frames.append(text) }
                onText(text, self)
            }
        }
    }

    /// Consume the HTTP upgrade head and return the 101 response, or nil if
    /// the head hasn't fully arrived. Caller holds the lock.
    private func takeHandshakeLocked() -> Data? {
        let marker: [UInt8] = Array("\r\n\r\n".utf8)
        guard let headEnd = pending.firstRange(of: marker) else { return nil }
        let head = String(decoding: pending[..<headEnd.lowerBound], as: UTF8.self)
        pending.removeSubrange(..<headEnd.upperBound)
        handshaken = true

        let key =
            head.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
            .split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let accept = Data(
            Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        ).base64EncodedString()
        return Data(
            ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                + "Connection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n").utf8)
    }

    /// Decode complete (masked) client frames off the buffer. Caller holds
    /// the lock.
    private func parseFramesLocked() -> [(opcode: UInt8, payload: Data)] {
        var decoded: [(UInt8, Data)] = []
        while pending.count >= 2 {
            let opcode = pending[0] & 0x0F
            let masked = pending[1] & 0x80 != 0
            var length = Int(pending[1] & 0x7F)
            var offset = 2
            if length == 126 {
                guard pending.count >= 4 else { break }
                length = Int(pending[2]) << 8 | Int(pending[3])
                offset = 4
            } else if length == 127 {
                guard pending.count >= 10 else { break }
                length = pending[2..<10].reduce(0) { $0 << 8 | Int($1) }
                offset = 10
            }
            let maskLength = masked ? 4 : 0
            guard pending.count >= offset + maskLength + length else { break }
            var payload = Array(pending[(offset + maskLength)..<(offset + maskLength + length)])
            if masked {
                let key = Array(pending[offset..<(offset + 4)])
                for index in payload.indices { payload[index] ^= key[index % 4] }
            }
            decoded.append((opcode, Data(payload)))
            pending.removeSubrange(..<(offset + maskLength + length))
        }
        return decoded
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((payload.count >> shift) & 0xFF))
            }
        }
        frame.append(payload)
        lock.withLock { connection }?.send(
            content: frame, isComplete: true, completion: .idempotent)
    }

    func send(_ text: String) {
        sendFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    /// Push a `{"method": "event"}` frame the way the gateway does.
    func sendEvent(type: String, sessionID: String? = nil, payload: String = "{}") {
        let session = sessionID.map { "\"session_id\": \"\($0)\"," } ?? ""
        send(
            #"{"jsonrpc": "2.0", "method": "event", "params": {"type": "\#(type)", \#(session) "payload": \#(payload)}}"#
        )
    }

    /// Answer a request by id with a raw JSON `result`.
    func respond(id: Int, result: String) {
        send(#"{"jsonrpc": "2.0", "id": \#(id), "result": \#(result)}"#)
    }

    func respondError(id: Int, code: Int, message: String) {
        send(
            #"{"jsonrpc": "2.0", "id": \#(id), "error": {"code": \#(code), "message": "\#(message)"}}"#
        )
    }

    /// Server-initiated close with an application close code (e.g. 4401).
    func close(code: UInt16) {
        sendFrame(opcode: 0x8, payload: Data([UInt8(code >> 8), UInt8(code & 0xFF)]))
    }

    func stop() {
        lock.withLock {
            connection?.cancel()
            connection = nil
        }
        listener.cancel()
    }
}

// MARK: - Scripted HTTP endpoint

struct CapturedHTTPRequest: Sendable {
    var method: String
    var path: String
    /// Header names lowercased.
    var headers: [String: String]
    var body: Data
}

struct ScriptedHTTPResponse: Sendable {
    var status: Int
    var body: String

    init(_ status: Int, _ body: String = "{}") {
        self.status = status
        self.body = body
    }
}

final class ScriptedHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private let handler: @Sendable (CapturedHTTPRequest) -> ScriptedHTTPResponse
    private(set) var port: UInt16 = 0

    var requests: [CapturedHTTPRequest] {
        lock.withLock { captured }
    }
    private var captured: [CapturedHTTPRequest] = []

    static func start(
        handler: @escaping @Sendable (CapturedHTTPRequest) -> ScriptedHTTPResponse
    ) async throws -> ScriptedHTTPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let server = ScriptedHTTPServer(listener: listener, handler: handler)
        try await server.waitUntilReady()
        return server
    }

    private init(
        listener: NWListener,
        handler: @escaping @Sendable (CapturedHTTPRequest) -> ScriptedHTTPResponse
    ) {
        self.listener = listener
        self.handler = handler
        // Installed BEFORE start() — see LocalGatewayServer.
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: DispatchQueue(label: "test.http-connection"))
            self?.receive(connection, buffer: Data())
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
            listener.start(queue: DispatchQueue(label: "test.http-server"))
        }
    }

    func stop() {
        listener.cancel()
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if let request = Self.parse(next) {
                self.lock.withLock { self.captured.append(request) }
                self.respond(connection, with: self.handler(request))
            } else if isComplete {
                connection.cancel()
            } else {
                self.receive(connection, buffer: next)
            }
        }
    }

    /// Returns the request once the head AND the Content-Length body have
    /// fully arrived; nil means keep reading.
    private static func parse(_ raw: Data) -> CapturedHTTPRequest? {
        guard let headEnd = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: raw[..<headEnd.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestParts = (lines.first ?? "").components(separatedBy: " ")
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        let body = raw[headEnd.upperBound...]
        guard body.count >= contentLength else { return nil }

        return CapturedHTTPRequest(
            method: requestParts[0],
            path: requestParts[1],
            headers: headers,
            body: Data(body.prefix(contentLength)))
    }

    private func respond(_ connection: NWConnection, with response: ScriptedHTTPResponse) {
        let reason = response.status == 200 ? "OK" : "Error"
        let text =
            "HTTP/1.1 \(response.status) \(reason)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(response.body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n\(response.body)"
        connection.send(
            content: Data(text.utf8), isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: - Shared

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
