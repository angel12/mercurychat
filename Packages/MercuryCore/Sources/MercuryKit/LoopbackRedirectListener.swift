import Foundation
import Network

/// Catches the `?code=&state=` redirect of a native-PKCE sign-in (RFC 8252):
/// a one-shot HTTP listener on 127.0.0.1 with an OS-assigned port. The
/// server's authorize endpoint only accepts loopback `http://` redirect URIs,
/// so this — not ASWebAuthenticationSession's https-only callbacks — is the
/// shape that works.
public actor LoopbackRedirectListener {
    public struct Redirect: Sendable, Equatable {
        public var code: String
        public var state: String
    }

    public enum ListenerError: Error, LocalizedError {
        case failedToStart
        case badRequest(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .failedToStart: return "Could not open a local sign-in listener."
            case .badRequest(let why): return "Sign-in redirect was malformed: \(why)"
            case .cancelled: return "Sign-in was cancelled."
            }
        }
    }

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var waiter: CheckedContinuation<Redirect, Error>?

    public init() {}

    /// Start listening; returns the redirect URI to hand to the authorize
    /// endpoint (`http://127.0.0.1:<port>/callback`).
    public func start() throws -> String {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else {
            throw ListenerError.failedToStart
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.start(queue: DispatchQueue(label: "mercury.pkce.listener"))

        // NWListener assigns the port synchronously for .any on start in
        // practice, but poll briefly to be safe.
        for _ in 0..<50 {
            if let port = listener.port, port.rawValue != 0 {
                return "http://127.0.0.1:\(port.rawValue)/callback"
            }
            usleep(20_000)
        }
        listener.cancel()
        throw ListenerError.failedToStart
    }

    /// Await the browser redirect. Single-shot; times out after `timeout`.
    public func waitForRedirect(timeout: TimeInterval = 300) async throws -> Redirect {
        defer { shutdown() }
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            self.failWaiter(ListenerError.cancelled)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    public func cancel() {
        failWaiter(ListenerError.cancelled)
        shutdown()
    }

    private func shutdown() {
        listener?.cancel()
        listener = nil
        for connection in connections { connection.cancel() }
        connections.removeAll()
    }

    private func failWaiter(_ error: Error) {
        waiter?.resume(throwing: error)
        waiter = nil
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: DispatchQueue(label: "mercury.pkce.connection"))
        receiveRequest(connection, buffer: Data())
    }

    private nonisolated func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            if error != nil {
                connection.cancel()
                return
            }
            // A GET's headers end at the blank line; that's all we need.
            if next.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete {
                Task { await self.handleRequest(next, on: connection) }
            } else if next.count < 64 * 1024 {
                self.receiveRequest(connection, buffer: next)
            } else {
                connection.cancel()
            }
        }
    }

    private func handleRequest(_ raw: Data, on connection: NWConnection) {
        guard let head = String(data: raw, encoding: .utf8),
            let requestLine = head.components(separatedBy: "\r\n").first,
            requestLine.hasPrefix("GET ")
        else {
            respond(connection, status: "400 Bad Request", body: "Bad request.")
            return
        }
        let target = requestLine.dropFirst(4).components(separatedBy: " ").first ?? ""
        guard let components = URLComponents(string: target) else {
            respond(connection, status: "400 Bad Request", body: "Bad request.")
            return
        }
        // Ignore favicon and stray probes; keep waiting for the redirect.
        guard components.path.hasSuffix("/callback") else {
            respond(connection, status: "404 Not Found", body: "Not found.")
            return
        }
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            })
        guard let code = query["code"], !code.isEmpty else {
            let detail = query["error"] ?? "missing code"
            respond(
                connection, status: "400 Bad Request",
                body: "Sign-in failed: \(detail). You can close this tab.")
            failWaiter(ListenerError.badRequest(detail))
            return
        }
        respond(
            connection, status: "200 OK",
            body: "Signed in. You can close this tab and return to Mercury.")
        waiter?.resume(returning: Redirect(code: code, state: query["state"] ?? ""))
        waiter = nil
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let html = "<html><body style=\"font-family:-apple-system\"><p>\(body)</p></body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { _ in connection.cancel() })
    }
}
