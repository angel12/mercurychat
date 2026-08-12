import Foundation
import Testing

@testable import MercuryKit

private func json(_ text: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Suite("TranscriptMessage parsing")
struct TranscriptMessageTests {
    @Test func parsesRESTRow() throws {
        let row = json(
            """
            {"id": 42, "role": "assistant", "content": "Hello",
             "reasoning": "let me think", "timestamp": 1754900000.5}
            """)
        let message = try #require(TranscriptMessage(json: row))
        #expect(message.rowID == 42)
        #expect(message.role == "assistant")
        #expect(message.text == "Hello")
        #expect(message.reasoning == "let me think")
        #expect(message.timestamp == Date(timeIntervalSince1970: 1_754_900_000.5))
        #expect(message.id == "row-42")
    }

    @Test func readsGatewayRowIDSpelling() throws {
        // The gateway resume path names the durable id `row_id`.
        let message = try #require(
            TranscriptMessage(json: json(#"{"row_id": 7, "role": "user", "content": "hi"}"#)))
        #expect(message.rowID == 7)
    }

    @Test func toolRowFields() throws {
        let row = json(
            """
            {"id": 3, "role": "tool", "tool_name": "terminal",
             "context": "ls -la", "content": "total 8", "tool_call_id": "abc"}
            """)
        let message = try #require(TranscriptMessage(json: row))
        #expect(message.toolName == "terminal")
        #expect(message.context == "ls -la")
        #expect(message.toolCallID == "abc")
    }

    @Test func emptyContentIsNothingNotError() throws {
        let message = try #require(
            TranscriptMessage(json: json(#"{"role": "assistant", "content": ""}"#)))
        #expect(message.text.isEmpty)
    }

    @Test func rejectsRowWithoutRole() {
        #expect(TranscriptMessage(json: json(#"{"content": "orphan"}"#)) == nil)
    }

    @Test func toleratesStructuredContent() throws {
        // Older/looser backends can ship non-string content; fall back to empty.
        let message = try #require(
            TranscriptMessage(
                json: json(#"{"role": "assistant", "content": [{"type": "text"}]}"#)))
        #expect(message.text.isEmpty)
    }
}

@Suite("TranscriptPage parsing")
struct TranscriptPageTests {
    @Test func parsesPagination() {
        let page = TranscriptPage(
            json: json(
                """
                {"session_id": "20260811_120000_ab12",
                 "messages": [{"id": 1, "role": "user", "content": "hi"}],
                 "pagination": {"limit": 500, "offset": 0, "order": "latest", "returned": 1}}
                """))
        #expect(page.sessionID == "20260811_120000_ab12")
        #expect(page.messages.count == 1)
        #expect(page.limit == 500)
        #expect(page.returned == 1)
    }
}

@Suite("TurnUsage parsing")
struct TurnUsageTests {
    @Test func parsesUsage() throws {
        let usage = try #require(
            TurnUsage(json: json(#"{"calls": 3, "input": 1200, "output": 450, "total": 1650}"#)))
        #expect(usage.calls == 3)
        #expect(usage.totalTokens == 1650)
    }

    @Test func derivesTotalWhenAbsent() throws {
        let usage = try #require(TurnUsage(json: json(#"{"input": 10, "output": 5}"#)))
        #expect(usage.totalTokens == 15)
    }

    @Test func nilForMissingPayload() {
        #expect(TurnUsage(json: nil) == nil)
        #expect(TurnUsage(json: .string("nope")) == nil)
    }
}

@Suite("Sudo/secret request payloads")
struct SecureRequestTests {
    @Test func parsesSecretRequest() throws {
        let event = GatewayEvent(
            type: "secret.request", sessionID: "ab12cd34",
            payload: json(
                #"{"request_id": "r1", "prompt": "Enter your API key", "env_var": "API_KEY"}"#))
        let request = try #require(SecretRequest(event: event))
        #expect(request.requestID == "r1")
        #expect(request.envVar == "API_KEY")
        #expect(request.prompt == "Enter your API key")
    }

    @Test func parsesSudoRequest() throws {
        let event = GatewayEvent(
            type: "sudo.request", sessionID: "ab12cd34",
            payload: json(#"{"request_id": "r2"}"#))
        let request = try #require(SudoRequest(event: event))
        #expect(request.requestID == "r2")
        #expect(request.sessionID == "ab12cd34")
    }

    @Test func requiresRequestID() {
        let event = GatewayEvent(type: "sudo.request", sessionID: "x", payload: .object([:]))
        #expect(SudoRequest(event: event) == nil)
    }
}

@Suite("PKCE")
struct PKCETests {
    @Test func generatesDistinctURLSafeChallenges() {
        let a = PKCEChallenge.generate()
        let b = PKCEChallenge.generate()
        #expect(a.verifier != b.verifier)
        #expect(a.state != b.state)
        let urlSafe = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(a.challenge.unicodeScalars.allSatisfy(urlSafe.contains))
        #expect(a.verifier.unicodeScalars.allSatisfy(urlSafe.contains))
    }

    @Test func challengeIsS256OfVerifier() {
        // RFC 7636 appendix B test vector.
        let challenge = PKCEChallenge(
            verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s")
        #expect(challenge.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func buildsAuthorizeURL() {
        let endpoint = ServerEndpoint(baseURL: URL(string: "https://hermes.example.com")!)
        let challenge = PKCEChallenge(verifier: "v", state: "csrf123")
        let url = HermesAuthenticator.nativeAuthorizeURL(
            endpoint: endpoint, provider: "nous", challenge: challenge,
            redirectURI: "http://127.0.0.1:53682/cb")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(components.path == "/auth/native/authorize")
        let query = Dictionary(
            uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(query["provider"] == "nous")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "csrf123")
        #expect(query["redirect_uri"] == "http://127.0.0.1:53682/cb")
    }
}

@Suite("Blocking-prompt response status")
struct PromptResponseStatusTests {
    private func decode(_ json: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test func acceptedStatusParses() throws {
        #expect(try PromptResponseStatus(result: decode(#"{"status": "ok"}"#)) == .accepted)
    }

    @Test func expiredStatusParses() throws {
        // A late answer resolves successfully at the transport level but was
        // NOT delivered — this must surface as .expired, never as accepted.
        #expect(try PromptResponseStatus(result: decode(#"{"status": "expired"}"#)) == .expired)
    }

    @Test func missingStatusThrows() {
        #expect(throws: HermesError.self) {
            _ = try PromptResponseStatus(result: decode("{}"))
        }
    }

    @Test func unknownStatusThrows() {
        // Fail closed: an unrecognized status must not be reported as
        // delivered — the caller keeps the prompt up and can retry (a retry
        // after actual delivery resolves as expired and closes cleanly).
        #expect(throws: HermesError.self) {
            _ = try PromptResponseStatus(result: decode(#"{"status": "later"}"#))
        }
    }
}
