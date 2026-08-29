import Foundation
import Testing

@testable import MercuryKit

/// The image-staging wrappers against a real local WebSocket server:
/// exact frame shape out, result parsing back.
@Suite("SessionAPI attachments", .timeLimit(.minutes(1)))
struct SessionAPIAttachmentsTests {
    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [JSONValue] = []
        func record(_ frame: JSONValue) { lock.withLock { frames.append(frame) } }
        var last: JSONValue? { lock.withLock { frames.last } }
    }

    private func readyConnection(port: UInt16) async throws -> HermesConnection {
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(port)").endpoint
        let connection = HermesConnection(endpoint: endpoint, token: "test-token")
        await connection.start()
        for await update in await connection.updates() {
            if case .phase(.ready) = update { break }
        }
        return connection
    }

    @Test func attachImageBytesSendsExpectedFrameAndParsesResult() async throws {
        let box = FrameBox()
        let server = try await LocalGatewayServer.start(onText: { text, server in
            guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                let id = frame["id"]?.intValue
            else { return }
            box.record(frame)
            server.respond(
                id: id,
                result: #"{"attached": true, "path": "/tmp/img/photo.jpg", "count": 1}"#)
        })
        defer { server.stop() }
        let connection = try await readyConnection(port: server.port)

        let attachment = try await connection.attachImageBytes(
            sessionID: "ab12", base64: "aGVsbG8=", filename: "photo.jpg")

        #expect(attachment.path == "/tmp/img/photo.jpg")
        #expect(attachment.count == 1)
        let frame = box.last
        #expect(frame?["method"]?.stringValue == "image.attach_bytes")
        #expect(frame?["params"]?["session_id"]?.stringValue == "ab12")
        #expect(frame?["params"]?["content_base64"]?.stringValue == "aGVsbG8=")
        #expect(frame?["params"]?["filename"]?.stringValue == "photo.jpg")
        await connection.stop()
    }

    @Test func attachImageBytesThrowsWhenNotConfirmed() async throws {
        let server = try await LocalGatewayServer.start(onText: { text, server in
            guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                let id = frame["id"]?.intValue
            else { return }
            server.respond(id: id, result: #"{"attached": false}"#)
        })
        defer { server.stop() }
        let connection = try await readyConnection(port: server.port)

        await #expect(throws: HermesError.self) {
            _ = try await connection.attachImageBytes(sessionID: "ab12", base64: "aGVsbG8=")
        }
        await connection.stop()
    }

    @Test func detachImageSendsSessionAndPath() async throws {
        let box = FrameBox()
        let server = try await LocalGatewayServer.start(onText: { text, server in
            guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                let id = frame["id"]?.intValue
            else { return }
            box.record(frame)
            server.respond(id: id, result: #"{"detached": true, "count": 0}"#)
        })
        defer { server.stop() }
        let connection = try await readyConnection(port: server.port)

        try await connection.detachImage(sessionID: "ab12", path: "/tmp/img/photo.jpg")

        let frame = box.last
        #expect(frame?["method"]?.stringValue == "image.detach")
        #expect(frame?["params"]?["session_id"]?.stringValue == "ab12")
        #expect(frame?["params"]?["path"]?.stringValue == "/tmp/img/photo.jpg")
        await connection.stop()
    }
}
