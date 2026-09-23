import ChatCore
import Foundation
import MercuryKit
import Testing

/// The Advanced bot editor's `AppModel` surface: load a profile, save the
/// sections a `BotProfileDraft` changed, and resend a guarded model once the
/// user confirms it (#B2).
@Suite("Bot Advanced Editor", .timeLimit(.minutes(1)))
@MainActor
struct BotAdvancedEditorTests {
    /// Scripted gateway state. `@unchecked` because access is lock-guarded.
    final class GatewayScript: @unchecked Sendable {
        private let lock = NSLock()
        private var profiles: [String: JSONValue]
        private var describeError: (name: String, code: Int, message: String)?
        /// Answers to `profiles.configure`, consumed in order; once empty,
        /// the default rule (every sent section applied) takes over.
        private var configureReplies: [JSONValue] = []
        /// When set, every subsequent `profiles.configure` fails with this
        /// RPC error instead of returning a reply.
        private var configureError: (code: Int, message: String)?
        private var modelInventoryReply: JSONValue

        init(
            profiles: [String: JSONValue] = ["scout": GatewayScript.scout],
            modelInventory: JSONValue = GatewayScript.inventory
        ) {
            self.profiles = profiles
            self.modelInventoryReply = modelInventory
        }

        static let scout: JSONValue = [
            "name": "scout",
            "description": "Finds things out",
            "soul": "You are Scout, a research bot.",
            "model": ["provider": "anthropic", "default": "claude-3-5-sonnet"],
            "skills": [["name": "web_search", "enabled": true]],
            "toolsets": [
                ["name": "core", "label": "Core", "description": "Core tools", "tool_count": 3, "enabled": true]
            ],
            "toolsets_pinned": false,
            "mcp_servers": [["name": "fs", "enabled": true, "transport": "stdio"]],
        ]

        static let inventory: JSONValue = [
            "model": "claude-3-5-sonnet",
            "provider": "anthropic",
            "providers": [
                [
                    "slug": "anthropic", "name": "Anthropic",
                    "models": ["claude-3-5-sonnet", "claude-3-opus"],
                    "is_current": true,
                ]
            ],
        ]

        /// Every subsequent `profiles.describe` for `name` fails with this
        /// RPC error instead of returning a profile.
        func failDescribe(name: String, code: Int, message: String) {
            lock.withLock { describeError = (name, code, message) }
        }

        /// Queue one scripted `profiles.configure` reply, consumed by the
        /// next such request; falls back to the default rule once drained.
        func enqueueConfigureReply(_ reply: JSONValue) {
            lock.withLock { configureReplies.append(reply) }
        }

        /// Every subsequent `profiles.configure` fails with this RPC error.
        func failConfigure(code: Int, message: String) {
            lock.withLock { configureError = (code, message) }
        }

        /// nil answers `{}`; an error is returned as `.error`.
        func respond(method: String, params: JSONValue) -> JSONValue? {
            lock.withLock {
                switch method {
                case "profiles.list":
                    return [
                        "profiles": .array(profiles.keys.sorted().map { ["name": .string($0), "path": "/p"] })
                    ]
                case "profiles.describe":
                    let name = params["name"]?.stringValue ?? ""
                    return profiles[name]
                case "profiles.configure":
                    if !configureReplies.isEmpty {
                        return configureReplies.removeFirst()
                    }
                    // Default: every section key present in the request is
                    // reported applied.
                    let sectionForParam: [String: String] = [
                        "soul": "soul",
                        "description": "description",
                        "model": "model",
                        "disabled_skills": "skills",
                        "enabled_toolsets": "toolsets",
                        "enabled_mcp_servers": "mcp_servers",
                    ]
                    var applied: [String: JSONValue] = [:]
                    for (paramKey, sectionKey) in sectionForParam where params[paramKey] != nil {
                        applied[sectionKey] = true
                    }
                    return ["ok": true, "applied": .object(applied)]
                case "model.options":
                    return modelInventoryReply
                default:
                    return [:]
                }
            }
        }

        /// nil unless `describeError` or `configureError` was armed for this
        /// request.
        func error(method: String, params: JSONValue) -> (Int, String)? {
            lock.withLock {
                if method == "profiles.describe",
                    let describeError, params["name"]?.stringValue == describeError.name
                {
                    return (describeError.code, describeError.message)
                }
                if method == "profiles.configure", let configureError {
                    return (configureError.code, configureError.message)
                }
                return nil
            }
        }
    }

    private func connectedModel(
        _ script: GatewayScript
    ) async throws -> (AppModel, HermesTestServer, () -> Void) {
        let server = try await HermesTestServer.start(
            rpc: { method, params in script.respond(method: method, params: params) },
            rpcError: { method, params in script.error(method: method, params: params) }
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
        // Bot Mode is probed after ready.
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

    // MARK: Loading

    @Test func loadingDescribesTheBot() async throws {
        let (model, server, cleanup) = try await connectedModel(GatewayScript())
        defer { cleanup() }

        let result = await model.loadBotProfile("scout")
        let profile = try result.get()
        #expect(profile.name == "scout")
        #expect(profile.soul == "You are Scout, a research bot.")
        #expect(requests("profiles.describe", in: server) == [["name": "scout"]])
    }

    /// The pinned MercuryKit maps `RPCCode.profileUnavailable` (4064) to a
    /// fixed, spoken-safe copy ("That profile isn't available on this
    /// server.") rather than echoing the backend's raw message — verified
    /// against `HermesError.errorDescription` at the exact pinned tag
    /// (0.3.0). `loadBotProfile` surfaces that mapped copy.
    @Test func aMissingBotShowsTheUnavailableMessage() async throws {
        let script = GatewayScript()
        script.failDescribe(name: "ghost", code: 4064, message: "Profile 'ghost' not found")
        let (model, _, cleanup) = try await connectedModel(script)
        defer { cleanup() }

        let result = await model.loadBotProfile("ghost")
        switch result {
        case .success:
            Issue.record("expected a failure for an unknown profile")
        case .failure(let error):
            #expect(error.message.contains("available"))
        }
    }

    // MARK: Saving

    @Test func savingSendsOnlyTheChangedSections() async throws {
        let (model, server, cleanup) = try await connectedModel(GatewayScript())
        defer { cleanup() }

        let profile = try (await model.loadBotProfile("scout")).get()
        var draft = BotProfileDraft(profile)
        draft.soul = "You are Scout, an even better research bot."

        let outcome = await model.saveBotProfile("scout", draft: draft)
        #expect(outcome == .saved)
        #expect(
            requests("profiles.configure", in: server)
                == [["name": "scout", "soul": "You are Scout, an even better research bot."]])
    }

    @Test func anUnchangedDraftSendsNothing() async throws {
        let (model, server, cleanup) = try await connectedModel(GatewayScript())
        defer { cleanup() }

        let profile = try (await model.loadBotProfile("scout")).get()
        let draft = BotProfileDraft(profile)

        let outcome = await model.saveBotProfile("scout", draft: draft)
        #expect(outcome == .saved)
        #expect(requests("profiles.configure", in: server).isEmpty)
    }

    @Test func aFailedSectionIsNamed() async throws {
        let script = GatewayScript()
        let (model, _, cleanup) = try await connectedModel(script)
        defer { cleanup() }

        script.enqueueConfigureReply(["ok": true, "applied": ["skills": false]])

        let profile = try (await model.loadBotProfile("scout")).get()
        var draft = BotProfileDraft(profile)
        draft.skills = draft.skills.map { skill in
            var skill = skill
            if skill.name == "web_search" { skill.enabled = false }
            return skill
        }

        let outcome = await model.saveBotProfile("scout", draft: draft)
        guard case .failed(let message) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(message.contains("Skills"))
    }

    @Test func aGuardedModelAsksThenConfirms() async throws {
        let script = GatewayScript()
        let (model, server, cleanup) = try await connectedModel(script)
        defer { cleanup() }

        script.enqueueConfigureReply([
            "ok": true, "applied": [:], "confirm_required": true, "confirm_message": "Costly",
        ])

        let profile = try (await model.loadBotProfile("scout")).get()
        var draft = BotProfileDraft(profile)
        let pin = ProfileDescription.ModelPin(provider: "anthropic", model: "claude-3-opus")
        draft.model = pin

        let outcome = await model.saveBotProfile("scout", draft: draft)
        #expect(outcome == .needsModelConfirmation("Costly"))

        let confirmError = await model.confirmBotModel("scout", pin: pin)
        #expect(confirmError == nil)

        let configureRequests = requests("profiles.configure", in: server)
        #expect(configureRequests.count == 2)
        #expect(configureRequests.first?["confirm_expensive_model"] == nil)
        #expect(
            configureRequests.last
                == [
                    "name": "scout", "model": "claude-3-opus", "provider": "anthropic",
                    "confirm_expensive_model": true,
                ])
    }

    @Test func aThrownSaveFails() async throws {
        let script = GatewayScript()
        let (model, _, cleanup) = try await connectedModel(script)
        defer { cleanup() }

        script.failConfigure(code: 5064, message: "boom")

        let profile = try (await model.loadBotProfile("scout")).get()
        var draft = BotProfileDraft(profile)
        draft.soul = "You are Scout, an even better research bot."

        let outcome = await model.saveBotProfile("scout", draft: draft)
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
    }

    /// Upstream skips a blank pin (empty model or provider) silently — no
    /// `applied[.model]` and no `confirm_required`. `saveBotProfile` must not
    /// read that as success when the draft actually changed the model.
    @Test func aModelTheGatewaySkippedFails() async throws {
        let script = GatewayScript()
        let (model, _, cleanup) = try await connectedModel(script)
        defer { cleanup() }

        script.enqueueConfigureReply(["ok": true, "applied": [:]])

        let profile = try (await model.loadBotProfile("scout")).get()
        var draft = BotProfileDraft(profile)
        draft.model = ProfileDescription.ModelPin(provider: "anthropic", model: "claude-3-opus")

        let outcome = await model.saveBotProfile("scout", draft: draft)
        guard case .failed(let message) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(message.contains("Model"))
    }

    // MARK: Model inventory

    @Test func theInventoryIsScopedToTheBot() async throws {
        let (model, server, cleanup) = try await connectedModel(GatewayScript())
        defer { cleanup() }

        let inventory = try #require(await model.botModelInventory("scout"))
        #expect(inventory.currentModel == "claude-3-5-sonnet")
        #expect(requests("model.options", in: server) == [["profile": "scout"]])
    }
}
