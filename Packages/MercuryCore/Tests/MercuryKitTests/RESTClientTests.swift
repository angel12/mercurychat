import Foundation
import Testing

@testable import MercuryKit

/// HermesRESTClient against a scripted local HTTP server: stored session ids
/// are interpolated into request paths, so every reserved character in an id
/// (above all `/`) must arrive single-percent-encoded — a raw `/` would
/// splice extra path segments into the route; a double-encoded `%252F`
/// would 404 server-side.
@Suite("HermesRESTClient", .timeLimit(.minutes(1)))
struct HermesRESTClientTests {
    private func client(port: UInt16) throws -> HermesRESTClient {
        HermesRESTClient(
            endpoint: try ServerEndpoint.parse("http://127.0.0.1:\(port)").endpoint,
            token: "tok")
    }

    @Test func sessionMessagesEncodesSlashInStoredID() async throws {
        let server = try await ScriptedHTTPServer.start { _ in
            ScriptedHTTPResponse(200, #"{"messages": []}"#)
        }
        defer { server.stop() }

        _ = try await client(port: server.port).sessionMessages(storedID: "a/b")

        #expect(server.requests.map(\.path) == ["/api/sessions/a%2Fb/messages"])
    }

    @Test func updateSessionEncodesReservedCharactersInStoredID() async throws {
        let server = try await ScriptedHTTPServer.start { _ in
            ScriptedHTTPResponse(200)
        }
        defer { server.stop() }

        // `/ : @ & + ,` all pass through `.urlPathAllowed` unencoded.
        try await client(port: server.port).updateSession(
            storedID: "a/b:c@d", title: "renamed")

        #expect(server.requests.map(\.method) == ["PATCH"])
        #expect(server.requests.map(\.path) == ["/api/sessions/a%2Fb%3Ac%40d"])
    }

    @Test func deleteSessionEncodesSlashInStoredID() async throws {
        let server = try await ScriptedHTTPServer.start { _ in
            ScriptedHTTPResponse(200)
        }
        defer { server.stop() }

        try await client(port: server.port).deleteSession(storedID: "a/b")

        #expect(server.requests.map(\.method) == ["DELETE"])
        #expect(server.requests.map(\.path) == ["/api/sessions/a%2Fb"])
    }
}
