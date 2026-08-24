import Foundation
import Testing

@testable import MercuryKit

/// HermesAuthenticator against a scripted local HTTP server: ticket minting,
/// the 401 → refresh → retry rotation, and dead-refresh-token handling.
@Suite("HermesAuthenticator", .timeLimit(.minutes(1)))
struct HermesAuthenticatorTests {
    private static func passwordSession(
        accessToken: String = "old-at", refreshToken: String = "old-rt"
    ) -> PasswordSession {
        PasswordSession(
            provider: "basic", username: "spencer",
            accessToken: accessToken, refreshToken: refreshToken, expiresAt: 0)
    }

    @Test func tokenModeAnswersWithoutAnyHTTP() async throws {
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:1").endpoint
        let authenticator = HermesAuthenticator(
            endpoint: endpoint, credentials: .sessionToken("tok"))

        let headers = await authenticator.authHeaders()
        #expect(headers == ["X-Hermes-Session-Token": "tok"])
        let query = try await authenticator.webSocketAuthQuery()
        #expect(query == [URLQueryItem(name: "token", value: "tok")])
    }

    @Test func passwordModeMintsAFreshTicketPerDial() async throws {
        let counter = Counter()
        let server = try await ScriptedHTTPServer.start { request in
            guard request.path == "/api/auth/ws-ticket" else {
                return ScriptedHTTPResponse(404)
            }
            return ScriptedHTTPResponse(200, #"{"ticket": "tik-\#(counter.next())"}"#)
        }
        defer { server.stop() }
        let authenticator = HermesAuthenticator(
            endpoint: try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint,
            credentials: .password(Self.passwordSession()))

        let first = try await authenticator.webSocketAuthQuery()
        let second = try await authenticator.webSocketAuthQuery()

        // Single-use 30s tickets: every dial must mint anew.
        #expect(first == [URLQueryItem(name: "ticket", value: "tik-1")])
        #expect(second == [URLQueryItem(name: "ticket", value: "tik-2")])
        #expect(
            server.requests.allSatisfy { $0.headers["authorization"] == "Bearer old-at" })
    }

    @Test func lapsedAccessTokenRotatesOnceAndRetries() async throws {
        let server = try await ScriptedHTTPServer.start { request in
            switch request.path {
            case "/api/auth/ws-ticket":
                // The old token is dead; the rotated one works.
                guard request.headers["authorization"] == "Bearer new-at" else {
                    return ScriptedHTTPResponse(401)
                }
                return ScriptedHTTPResponse(200, #"{"ticket": "tik-after-refresh"}"#)
            case "/auth/native/refresh":
                let body = try? JSONDecoder().decode(JSONValue.self, from: request.body)
                guard body?["refresh_token"]?.stringValue == "old-rt" else {
                    return ScriptedHTTPResponse(401)
                }
                return ScriptedHTTPResponse(
                    200,
                    #"{"access_token": "new-at", "refresh_token": "new-rt", "expires_at": 99}"#
                )
            default:
                return ScriptedHTTPResponse(404)
            }
        }
        defer { server.stop() }

        let rotated = CapturedCredentials()
        let authenticator = HermesAuthenticator(
            endpoint: try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint,
            credentials: .password(Self.passwordSession())
        ) { rotated.record($0) }

        let query = try await authenticator.webSocketAuthQuery()

        #expect(query == [URLQueryItem(name: "ticket", value: "tik-after-refresh")])
        // The rotation was persisted (keychain callback) with both tokens.
        guard case .password(let session)? = rotated.last else {
            Issue.record("no rotated credentials were published")
            return
        }
        #expect(session.accessToken == "new-at")
        #expect(session.refreshToken == "new-rt")
        #expect(session.expiresAt == 99)
        // 401 ticket → refresh → retried ticket: exactly three requests.
        #expect(server.requests.map(\.path) == [
            "/api/auth/ws-ticket", "/auth/native/refresh", "/api/auth/ws-ticket",
        ])
    }

    @Test func deadRefreshTokenSignalsSessionExpired() async throws {
        let server = try await ScriptedHTTPServer.start { request in
            // Every provider rejects both the access and refresh tokens.
            ScriptedHTTPResponse(401)
        }
        defer { server.stop() }
        let authenticator = HermesAuthenticator(
            endpoint: try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint,
            credentials: .password(Self.passwordSession()))

        do {
            _ = try await authenticator.webSocketAuthQuery()
            Issue.record("expected sessionExpired")
        } catch HermesError.sessionExpired {
            // The recoverable-auth signal the app maps to a fresh sign-in.
        }
    }
}

// MARK: - Helpers

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

private final class CapturedCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [ServerCredentials] = []

    var last: ServerCredentials? {
        lock.withLock { captured.last }
    }

    func record(_ credentials: ServerCredentials) {
        lock.withLock { captured.append(credentials) }
    }
}
