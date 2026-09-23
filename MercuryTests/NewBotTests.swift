import ChatCore
import Foundation
import MercuryKit
import Testing

/// The New Bot quick path (#27 Phase 3): create the profile the way hermes
/// desktop does, give it its title, and open its Bot Chat with the
/// self-introduction kickoff, sent once.
@Suite("New Bot", .timeLimit(.minutes(1)))
@MainActor
struct NewBotTests {
    /// Scripted gateway state. `@unchecked` because access is lock-guarded.
    final class GatewayScript: @unchecked Sendable {
        private let lock = NSLock()
        private var existing: [String]
        private var createError: (Int, String)?

        init(existing: [String] = ["default"]) { self.existing = existing }

        func failCreate(code: Int, message: String) { lock.withLock { createError = (code, message) } }

        /// nil answers `{}`; an error is returned as `.error`.
        func respond(method: String, params: JSONValue) -> JSONValue? {
            lock.withLock {
                switch method {
                case "profiles.list":
                    return .object([
                        "profiles": .array(existing.map { .object(["name": .string($0), "path": "/p"]) })
                    ])
                case "profiles.create":
                    if createError != nil { return nil }
                    let name = params["name"]?.stringValue ?? ""
                    existing.append(name)
                    return .object([
                        "ok": true, "name": .string(name), "path": .string("/p/\(name)"),
                        "soul_written": true, "model_set": false,
                        "mirrored": ["env": true, "auth": "shared", "model_inherited": true, "voice": false],
                    ])
                case "profiles.configure":
                    return .object(["ok": true, "applied": ["ui_meta": true]])
                case "session.list":
                    return .object(["sessions": .array([])])
                case "session.create":
                    return .object(["session_id": "rt-created"])
                default:
                    return .object([:])
                }
            }
        }

        var createFailure: (Int, String)? { lock.withLock { createError } }
    }

    private func connectedModel(
        _ script: GatewayScript
    ) async throws -> (AppModel, HermesTestServer, () -> Void) {
        let server = try await HermesTestServer.start(
            rpc: { method, params in script.respond(method: method, params: params) },
            rpcError: { method, _ in
                method == "profiles.create" ? script.createFailure : nil
            }
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
        // Bot Mode is probed after ready; creation needs it.
        try #require(await eventually { model.botModeSupported == true })
        await model.loadBots(force: true)
        return (
            model, server,
            {
                model.disconnect()
                server.stop()
                try? store.deleteToken(for: endpoint)
            }
        )
    }

    private func requests(_ method: String, in server: HermesTestServer) -> [JSONValue] {
        server.rpcRequests.filter { $0.method == method }.map(\.params)
    }

    // MARK: Creating

    @Test func createsTheProfileTheWayTheDesktopDoes() async throws {
        let (model, server, cleanup) = try await connectedModel(GatewayScript())
        defer { cleanup() }

        let error = await model.createBot(
            name: "Scout", title: "Researcher", description: "Finds things out")
        #expect(error == nil)

        #expect(
            requests("profiles.create", in: server)
                == [
                    [
                        "name": "scout",
                        "description": "Researcher — Finds things out",
                        "clone_from": "default",
                        "share_auth": true,
                        "soul": .string(
                            BotCreation.soul(slug: "scout", title: "Researcher", description: "Finds things out")),
                    ]
                ])

        // The look: the title, and when it was created (epoch milliseconds,
        // as the desktop writes it). No CAS revision on a brand-new profile.
        let configure = try #require(requests("profiles.configure", in: server).last)
        #expect(configure["name"] == "scout")
        #expect(configure["ui_meta_expected_revisions"] == nil)
        let meta = try #require(configure["ui_meta"]?["hermes-bots"]?.objectValue)
        #expect(meta["title"] == "Researcher")
        let created = try #require(meta["created"]?.doubleValue)
        #expect(abs(created - Date().timeIntervalSince1970 * 1000) < 60_000)
        #expect(meta.keys.sorted() == ["created", "title"])

        // The roster was refreshed and the new bot's chat opened, with the
        // self-introduction armed.
        #expect(model.bots.contains { $0.name == "scout" })
        #expect(
            model.route
                == .botChat(.init(profile: "scout", displayTitle: "Researcher", storedID: nil, kickoff: true)))
    }

    @Test func cloningAnotherBotSendsItsName() async throws {
        let (model, server, cleanup) = try await connectedModel(GatewayScript(existing: ["default", "scout"]))
        defer { cleanup() }

        let error = await model.createBot(
            name: "Scout Two", title: "", description: "", cloneFrom: "scout")
        #expect(error == nil)

        let create = try #require(requests("profiles.create", in: server).last)
        #expect(create["clone_from"] == "scout")
        #expect(create["share_auth"] == true)
        #expect(
            create["soul"]
                == .string(BotCreation.soul(slug: "scout-two", title: "", description: "")))
    }

    @Test func aFreshProfileSendsNoCloneSource() async throws {
        let (model, server, cleanup) = try await connectedModel(GatewayScript(existing: ["default", "scout"]))
        defer { cleanup() }

        let error = await model.createBot(
            name: "Scout Three", title: "", description: "", cloneFrom: nil)
        #expect(error == nil)

        let create = try #require(requests("profiles.create", in: server).last)
        #expect(create["clone_from"] == nil)
        #expect(create["share_auth"] == true)
        #expect(
            create["soul"]
                == .string(BotCreation.soul(slug: "scout-three", title: "", description: "")))
    }

    @Test func aNameOnlyBotHasNoTitleInItsLook() async throws {
        let (model, server, cleanup) = try await connectedModel(GatewayScript())
        defer { cleanup() }

        #expect(await model.createBot(name: "Inbox Triage", title: "", description: "") == nil)
        let create = try #require(requests("profiles.create", in: server).last)
        #expect(create["name"] == "inbox-triage")
        #expect(create["description"] == nil)
        let meta = try #require(requests("profiles.configure", in: server).last?["ui_meta"]?["hermes-bots"]?.objectValue)
        #expect(meta.keys.sorted() == ["created"])
        #expect(
            model.route
                == .botChat(.init(profile: "inbox-triage", displayTitle: "Inbox Triage", storedID: nil, kickoff: true)))
    }

    // MARK: Refusals

    @Test func aNameWithNothingUsableIsRefusedBeforeAnyCall() async throws {
        let (model, server, cleanup) = try await connectedModel(GatewayScript())
        defer { cleanup() }

        let error = await model.createBot(name: "🤖", title: "", description: "")
        #expect(error?.contains("letters or numbers") == true)
        #expect(requests("profiles.create", in: server).isEmpty)
        #expect(model.route == nil)
    }

    @Test func aTakenNameIsRefusedBeforeAnyCall() async throws {
        let (model, server, cleanup) = try await connectedModel(GatewayScript(existing: ["default", "scout"]))
        defer { cleanup() }

        let error = await model.createBot(name: "Scout", title: "", description: "")
        #expect(error?.contains("scout") == true)
        #expect(requests("profiles.create", in: server).isEmpty)
    }

    /// The backend's own reason (a reserved or taken name) reaches the user.
    @Test func aBackendRefusalShowsItsMessage() async throws {
        let script = GatewayScript()
        script.failCreate(code: 4062, message: "Profile name 'test' is reserved")
        let (model, server, cleanup) = try await connectedModel(script)
        defer { cleanup() }

        let error = await model.createBot(name: "Test", title: "", description: "")
        #expect(error?.contains("Profile name 'test' is reserved") == true)
        #expect(requests("profiles.configure", in: server).isEmpty)
        #expect(model.route == nil)
    }

    // MARK: Kickoff

    /// The self-introduction goes into the new, empty Bot Chat once. Opening
    /// the chat again (or a chat with a transcript) sends nothing.
    @Test func theKickoffIsSentOnceIntoAFreshChat() async throws {
        let (model, server, cleanup) = try await connectedModel(GatewayScript(existing: ["default", "scout"]))
        defer { cleanup() }

        let chat = try #require(model.openChat(profile: "scout"))
        chat.isCanonicalBotChat = true
        await chat.begin(.bot(profile: "scout", expectCanonical: false))
        #expect(chat.runtimeID == "rt-created")

        await chat.sendKickoffIfFresh()
        await chat.sendKickoffIfFresh()

        let prompts = requests("prompt.submit", in: server)
        #expect(prompts.count == 1)
        #expect(prompts.first?["text"] == .string(BotCreation.kickoff))
    }
}
