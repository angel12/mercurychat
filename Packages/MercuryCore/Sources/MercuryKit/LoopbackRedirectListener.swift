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
    private var readyWaiter: CheckedContinuation<UInt16, Error>?
    /// Set once cancelled/shut down, so a waiter that installs afterwards
    /// (cancellation raced ahead of `waitForRedirect`) fails immediately
    /// instead of suspending forever.
    private var isFinished = false

    public init() {}

    /// Start listening; returns the redirect URI to hand to the authorize
    /// endpoint (`http://127.0.0.1:<port>/callback`).
    ///
    /// Returns only once the listener is `.ready`: the port is assigned
    /// before the socket actually accepts, and a browser redirected in that
    /// window would see connection-refused.
    public func start() async throws -> String {
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
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.listenerStateChanged(state) }
        }
        listener.start(queue: DispatchQueue(label: "mercury.pkce.listener"))

        let startTimeout = Task {
            try? await Task.sleep(for: .seconds(5))
            self.failReadyWaiter()
        }
        defer { startTimeout.cancel() }
        do {
            let port = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<UInt16, Error>) in
                if isFinished {
                    continuation.resume(throwing: ListenerError.failedToStart)
                    return
                }
                readyWaiter = continuation
            }
            return "http://127.0.0.1:\(port)/callback"
        } catch {
            shutdown()
            throw error
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port?.rawValue, port != 0 {
                readyWaiter?.resume(returning: port)
                readyWaiter = nil
            } else {
                failReadyWaiter()
            }
        case .failed, .cancelled:
            failReadyWaiter()
        default:
            break
        }
    }

    private func failReadyWaiter() {
        readyWaiter?.resume(throwing: ListenerError.failedToStart)
        readyWaiter = nil
    }

    /// Await the browser redirect. Single-shot; times out after `timeout`.
    /// Cancelling the awaiting task tears the listener down immediately and
    /// throws `ListenerError.cancelled` — the port must not stay open for
    /// the full timeout after the user backs out of sign-in.
    public func waitForRedirect(timeout: TimeInterval = 300) async throws -> Redirect {
        defer { shutdown() }
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            self.failWaiter(ListenerError.cancelled)
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if isFinished {
                    continuation.resume(throwing: ListenerError.cancelled)
                    return
                }
                waiter = continuation
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    public func cancel() {
        failWaiter(ListenerError.cancelled)
        shutdown()
    }

    private func shutdown() {
        isFinished = true
        failReadyWaiter()
        listener?.stateUpdateHandler = nil
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
        // Query items are attacker-controlled: build the map without the
        // duplicate-key precondition of Dictionary(uniqueKeysWithValues:),
        // and refuse ambiguous security parameters outright. Keep waiting —
        // a malformed probe must not kill a legitimate sign-in in progress.
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            let isDuplicate = query.updateValue(item.value ?? "", forKey: item.name) != nil
            if isDuplicate, ["code", "state", "error"].contains(item.name) {
                respond(
                    connection, status: "400 Bad Request",
                    body: "Bad request: duplicate \(item.name) parameter.")
                return
            }
        }
        // An RFC 6749 error redirect (e.g. `error=access_denied`) is the
        // server definitively ending the flow: fail the wait so the app can
        // surface the reason. The value is attacker-controlled — never
        // interpolate it into the page; it reaches the UI via the error only.
        if let oauthError = query["error"], !oauthError.isEmpty {
            respond(
                connection, status: "400 Bad Request",
                body: "Sign-in failed. You can close this tab and return to Mercury.")
            failWaiter(ListenerError.badRequest(oauthError))
            return
        }
        // Neither code nor error: a stray local probe, not the browser
        // redirect. Keep waiting — failing the waiter here would run
        // waitForRedirect's shutdown and close the port under a live sign-in.
        guard let code = query["code"], !code.isEmpty else {
            respond(connection, status: "400 Bad Request", body: "Waiting for sign-in.")
            return
        }
        respond(
            connection, status: "200 OK",
            body: "Signed in. You can close this tab and return to Mercury.")
        waiter?.resume(returning: Redirect(code: code, state: query["state"] ?? ""))
        waiter = nil
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        // Escape unconditionally: the loopback page is a real browsing
        // context, so no caller may reflect attacker-controlled text as
        // markup, even if a future branch forgets and interpolates one.
        let html =
            "<html><body style=\"font-family:-apple-system\"><p>\(Self.htmlEscaped(body))</p></body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        // Graceful close, not cancel-on-send: an abortive cancel() can RST
        // the response out from under the peer before it reads the bytes —
        // the browser then shows a connection error instead of this page and
        // may retry against a port that is already shut down (resuming the
        // waiter runs waitForRedirect's shutdown immediately). Detach the
        // connection from the shutdown kill-list, mark the response final
        // (FIN after content), and let it drain until the peer closes, with
        // a failsafe timer so an unresponsive peer can't pin the socket.
        connections.removeAll { $0 === connection }
        connection.send(
            content: Data(response.utf8),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
                Self.drainThenCancel(connection)
            })
    }

    private nonisolated static func htmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Read until the peer closes (or errors), then cancel. A failsafe
    /// timer cancels regardless — cancel() is idempotent, so racing the
    /// EOF path is harmless.
    private nonisolated static func drainThenCancel(_ connection: NWConnection) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { connection.cancel() }
        receiveToEOF(connection) { connection.cancel() }
    }

    private nonisolated static func receiveToEOF(
        _ connection: NWConnection, then done: @escaping @Sendable () -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            _, _, isComplete, error in
            if isComplete || error != nil {
                done()
            } else {
                receiveToEOF(connection, then: done)
            }
        }
    }
}
