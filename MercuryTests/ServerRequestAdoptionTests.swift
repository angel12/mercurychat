import Foundation
import MercuryKit
import Testing

/// Desktop contract 7 (#27, Phase 2.5 M2): blocking prompts are server→client
/// requests. Chat advertises `client.capabilities {server_requests: true}`,
/// restores open requests from a resume, and answers through `request.answer`,
/// `clarify.lock` and `connection.respond`. Upstream rejects an undeclared
/// param key with 4000, so the exact shapes are the contract.
@Suite("Contract-7 server requests", .timeLimit(.minutes(1)))
@MainActor
struct ServerRequestAdoptionTests {
    /// Scripted gateway state. `@unchecked` because access is lock-guarded.
    final class GatewayScript: @unchecked Sendable {
        private let lock = NSLock()
        private var contract: Int?
        private var answerStatus = "ok"
        private var resumeExtras: [String: JSONValue] = [:]

        init(contract: Int?) { self.contract = contract }

        func setAnswerStatus(_ status: String) { lock.withLock { answerStatus = status } }
        func setResumeExtras(_ extras: [String: JSONValue]) { lock.withLock { resumeExtras = extras } }

        func respond(method: String, params: JSONValue) -> JSONValue? {
            lock.withLock {
                var info: [String: JSONValue] = [:]
                if let contract { info["desktop_contract"] = .number(Double(contract)) }
                switch method {
                case "session.create":
                    // AppModel's connect-time contract probe.
                    return .object(["session_id": "rt-probe", "info": .object(info)])
                case "session.resume":
                    var result: [String: JSONValue] = [
                        "session_id": "rt-1", "stored_session_id": "stored-1", "info": .object(info),
                    ]
                    for (key, value) in resumeExtras { result[key] = value }
                    return .object(result)
                case "request.answer":
                    return .object(["status": .string(answerStatus)])
                case "clarify.lock":
                    return .object(["status": "ok", "remaining": ["q2"]])
                case "connection.respond":
                    return .object(["status": "ok", "settled": true])
                default:
                    return .object([:])
                }
            }
        }
    }

    private func connectedModel(
        _ script: GatewayScript
    ) async throws -> (AppModel, HermesTestServer, () -> Void) {
        let server = try await HermesTestServer.start(
            rpc: { method, params in script.respond(method: method, params: params) }
        ) { request in
            switch (request.method, request.path) {
            case ("GET", "/api/status"):
                return TestHTTPResponse(200, #"{"auth_required": false}"#)
            default:
                return TestHTTPResponse(200, #"{"messages": []}"#)
            }
        }
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        let model = AppModel(tokenStore: store)
        await model.connect(endpoint: endpoint, credentials: nil)
        let ready = await eventually {
            if case .ready = model.phase { return true }
            return false
        }
        try #require(ready)
        return (
            model, server,
            {
                model.disconnect()
                server.stop()
                try? store.deleteToken(for: endpoint)
            }
        )
    }

    /// Open the stored session "stored-1" and resume it.
    private func resumedChat(_ model: AppModel) async throws -> ChatController {
        let chat = try #require(model.openChat(profile: nil))
        let summary = try #require(SessionSummary(json: ["id": "stored-1"]))
        await chat.begin(.resume(summary))
        try #require(chat.runtimeID == "rt-1")
        return chat
    }

    private func last(_ method: String, in server: HermesTestServer) -> JSONValue? {
        server.rpcRequests.last { $0.method == method }?.params
    }

    private static let approvalRequest: JSONValue = [
        "id": "srq-aaaaaaaaaaa1", "method": "approval",
        "params": ["session_id": "rt-1", "request_id": "ap1", "command": "rm -rf build"],
    ]

    // MARK: Advertising and the contract notice

    @Test func eachSocketAdvertisesServerRequests() async throws {
        let (_, server, cleanup) = try await connectedModel(GatewayScript(contract: 8))
        defer { cleanup() }
        let advert = try #require(last("client.capabilities", in: server))
        #expect(advert == ["server_requests": true])
    }

    @Test(arguments: [(6, true), (7, false), (8, false)])
    func aBackendBelowContract7GetsANotice(contract: Int, expectNotice: Bool) async throws {
        let (model, server, cleanup) = try await connectedModel(GatewayScript(contract: contract))
        defer { cleanup() }
        // The probe runs after ready and closes its throwaway session; the
        // verdict is final once that close has gone out.
        let probed = await eventually { server.rpcRequests.contains { $0.method == "session.close" } }
        try #require(probed)
        let noticed = await eventually(within: 1) { model.contractNotice != nil }
        #expect(noticed == expectNotice)
        if expectNotice {
            #expect(model.contractNotice?.contains("v\(contract)") == true)
            #expect(model.contractNotice?.contains("v7") == true)
        }
    }

    // MARK: Restoring open requests

    @Test func resumeRestoresOpenRequestsItAnswers() async throws {
        let script = GatewayScript(contract: 8)
        script.setResumeExtras([
            "running": true,
            "open_requests": [
                Self.approvalRequest,
                // Not a method Chat answers: left for other clients.
                ["id": "srq-bbbbbbbbbbb1", "method": "vault.read", "params": ["session_id": "rt-1", "path": "x"]],
            ],
        ])
        let (model, _, cleanup) = try await connectedModel(script)
        defer { cleanup() }
        let chat = try await resumedChat(model)

        #expect(chat.store.pendingApproval?.serverRequestID == "srq-aaaaaaaaaaa1")
        #expect(chat.store.pendingApproval?.command == "rm -rf build")
        #expect(chat.store.pendingClarify == nil)
    }

    @Test func resumeRestoresAPendingConnection() async throws {
        let script = GatewayScript(contract: 8)
        script.setResumeExtras([
            "running": true,
            "pending_connection": [
                "op_id": "op-1", "seq": 1, "deadline_at": 1_790_000_000, "timeout_seconds": 600,
                "targets": [["name": "linear", "kind": "mcp", "action": "install", "state": "pending"]],
            ],
        ])
        let (model, _, cleanup) = try await connectedModel(script)
        defer { cleanup() }
        let chat = try await resumedChat(model)
        #expect(chat.store.pendingConnection?.opID == "op-1")
    }

    // MARK: Answers

    @Test func approvalAnswersTheServerRequest() async throws {
        let script = GatewayScript(contract: 8)
        script.setResumeExtras(["running": true, "open_requests": [Self.approvalRequest]])
        let (model, server, cleanup) = try await connectedModel(script)
        defer { cleanup() }
        let chat = try await resumedChat(model)
        let approval = try #require(chat.store.pendingApproval)

        #expect(await chat.respondApproval(approval, choice: "once"))
        #expect(last("request.answer", in: server) == ["id": "srq-aaaaaaaaaaa1", "result": ["choice": "once"]])
        #expect(chat.store.pendingApproval == nil)
    }

    @Test func clarifySudoAndSecretAnswerTheServerRequest() async throws {
        let (model, server, cleanup) = try await connectedModel(GatewayScript(contract: 8))
        defer { cleanup() }
        let chat = try await resumedChat(model)

        #expect(await chat.respondClarify(requestID: "srq-ccccccccccc1", answer: "dev") == .delivered)
        #expect(last("request.answer", in: server) == ["id": "srq-ccccccccccc1", "result": ["answer": "dev"]])

        #expect(await chat.respondSudo(requestID: "srq-ccccccccccc2", password: "pw") == .delivered)
        #expect(last("request.answer", in: server) == ["id": "srq-ccccccccccc2", "result": ["value": "pw"]])

        #expect(await chat.respondSecret(requestID: "srq-ccccccccccc3", value: "sk") == .delivered)
        #expect(last("request.answer", in: server) == ["id": "srq-ccccccccccc3", "result": ["value": "sk"]])
    }

    @Test func batchClarifyLocksOneAnswer() async throws {
        let (model, server, cleanup) = try await connectedModel(GatewayScript(contract: 8))
        defer { cleanup() }
        let chat = try await resumedChat(model)

        let outcome = await chat.respondClarifyQuestion(
            requestID: "srq-ddddddddddd1", questionID: "q1", answer: "dev")
        guard case .progress(let remaining) = outcome else {
            Issue.record("expected progress, got \(outcome)")
            return
        }
        #expect(remaining == ["q2"])
        #expect(
            last("clarify.lock", in: server)
                == ["request_id": "srq-ddddddddddd1", "question_id": "q1", "answer": "dev"])
    }

    /// Upstream's `ClarifyResult`: a batch is cancelled by a result with
    /// neither `answer` nor `answers`.
    @Test func skippingABatchClarifySendsCancelAll() async throws {
        let (model, server, cleanup) = try await connectedModel(GatewayScript(contract: 8))
        defer { cleanup() }
        let chat = try await resumedChat(model)

        #expect(await chat.skipBatchClarify(requestID: "srq-fffffffffff1") == .delivered)
        #expect(last("request.answer", in: server) == ["id": "srq-fffffffffff1", "result": .object([:])])
    }

    @Test func anExpiredAnswerIsReportedAndLeavesANotice() async throws {
        let script = GatewayScript(contract: 8)
        script.setAnswerStatus("expired")
        let (model, _, cleanup) = try await connectedModel(script)
        defer { cleanup() }
        let chat = try await resumedChat(model)

        #expect(await chat.respondClarify(requestID: "srq-eeeeeeeeeee1", answer: "dev") == .expired)
        let noticed = chat.store.items.contains {
            if case .notice(let notice) = $0 { return notice.text.contains("expired") }
            return false
        }
        #expect(noticed)
    }

    /// `connection.respond` changed shape at contract 8: `owner` replaced
    /// `session_id`. Chat can't run MCP installs, so its only answer skips
    /// every target and lets the agent continue.
    @Test(arguments: [7, 8])
    func skippingAConnectionUsesTheSessionsContractShape(contract: Int) async throws {
        let script = GatewayScript(contract: contract)
        script.setResumeExtras([
            "running": true,
            "pending_connection": [
                "op_id": "op-1", "seq": 1, "deadline_at": 1_790_000_000, "timeout_seconds": 600,
                "targets": [
                    ["name": "linear", "kind": "mcp", "action": "install", "state": "pending"],
                    ["name": "github", "kind": "connector", "action": "connect", "state": "pending"],
                ],
            ],
        ])
        let (model, server, cleanup) = try await connectedModel(script)
        defer { cleanup() }
        let chat = try await resumedChat(model)
        let request = try #require(chat.store.pendingConnection)

        #expect(await chat.skipConnection(request) == .delivered)
        var expected: [String: JSONValue] = [
            "op_id": "op-1",
            "result": [
                "targets": [["name": "linear", "status": "skipped"], ["name": "github", "status": "skipped"]],
                "settled_by": "continue",
            ],
        ]
        if contract < 8 {
            expected["session_id"] = "rt-1"
        } else {
            expected["owner"] = ["type": "session", "session_id": "rt-1"]
        }
        #expect(last("connection.respond", in: server) == .object(expected))
        #expect(chat.store.pendingConnection == nil)
    }
}
