import Foundation
import MercuryKit
@testable import MercuryVoiceEngine
import Testing

/// AppModel answers the voice intents (sub-project 5).
extension SharedMeterTests {
    @MainActor
    @Suite("Voice intent host")
    struct VoiceIntentHostTests {

        struct Harness {
            let model: AppModel
            let system: FakeVoiceCallSystem
            let cleanup: () -> Void
        }

        /// As `VoiceCallHostTests.connected`, with a fake call system and one
        /// recent session (no profile of its own).
        private func connected() async throws -> Harness {
            let script = MultiWindowChatTests.Script()
            let server = try await HermesTestServer.start(
                rpc: { method, params in script.respond(method: method, params: params) }
            ) { request in
                switch (request.method, request.path) {
                case ("GET", "/api/status"):
                    return TestHTTPResponse(200, #"{"auth_required": false}"#)
                case ("GET", "/api/profiles/sessions"):
                    return TestHTTPResponse(
                        200, #"{"sessions": [{"session_id": "s-1", "title": ""}]}"#)
                default:
                    return TestHTTPResponse(200, #"{"messages": []}"#)
                }
            }
            let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
            let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
            let model = AppModel(tokenStore: store)
            let voices = ConversationRecorder()
            voices.script = { index, service in
                let answer = Fixtures.resumeResult(
                    runtimeID: "rt-v\(index)", storedID: "stored-v\(index)")
                service.enqueueCreate(answer)
                service.enqueueResume(answer)
            }
            model.makeVoiceController = { voices.make(connection: $0, profile: $1) }
            let system = FakeVoiceCallSystem()
            model.voiceCallCenter = VoiceCallCenter(system: system, sleep: { _ in })
            await model.connect(endpoint: endpoint, credentials: nil)
            let ready = await eventually {
                if case .ready = model.phase { return true }
                return false
            }
            try #require(ready)
            return Harness(
                model: model, system: system,
                cleanup: {
                    server.stop()
                    try? store.deleteToken(for: endpoint)
                })
        }

        private func startedVoice(_ h: Harness) async throws {
            try await h.model.intentStartVoice(.new(profile: nil))
            await h.model.voiceLaunch?.value
            try #require(h.model.voiceConversation != nil)
            // The engine is built once the begin finished.
            #expect(await eventually { h.system.starts.count == 1 })
        }

        @Test func startIntentStartsANewConversation() async throws {
            let h = try await connected(); defer { h.cleanup() }
            try await startedVoice(h)
            guard case .new(nil, nil, _) = h.model.voiceConversation?.target else {
                Issue.record("expected a new-conversation target")
                return
            }
            h.model.endVoice()
        }

        @Test func startIntentWhileDisconnectedTimesOut() async {
            let model = AppModel(tokenStore: KeychainTokenStore(service: "com.mercury.tokens.tests"))
            model.voiceIntentConnectTimeout = .milliseconds(50)
            await #expect(throws: VoiceIntentError.notConnected) {
                try await model.intentStartVoice(.new(profile: nil))
            }
            #expect(model.voiceConversation == nil)
        }

        @Test func muteIntentReachesTheCallAndIsIdempotent() async throws {
            let h = try await connected(); defer { h.cleanup() }
            try await startedVoice(h)
            #expect(try await h.model.intentSetMute(true) == true)
            #expect(await eventually { h.system.mutes.map(\.muted) == [true] })
            #expect(try await h.model.intentSetMute(true) == true)
            #expect(try await h.model.intentSetMute(nil) == false)
            #expect(await eventually { h.system.mutes.map(\.muted) == [true, false] })
            try await Task.sleep(for: .milliseconds(100))
            #expect(h.system.mutes.count == 2)
            h.model.endVoice()
        }

        @Test func muteAndEndWithoutConversationFail() async throws {
            let model = AppModel(tokenStore: KeychainTokenStore(service: "com.mercury.tokens.tests"))
            await #expect(throws: VoiceIntentError.noConversation) {
                _ = try await model.intentSetMute(nil)
            }
            #expect(throws: VoiceIntentError.noConversation) { try model.intentEndVoice() }
            #expect(model.isVoiceActive == false)
        }

        @Test func endIntentEndsTheConversationAndReportsActivity() async throws {
            let h = try await connected(); defer { h.cleanup() }
            var activity: [Bool] = []
            h.model.onVoiceActiveChanged = { activity.append($0) }
            try await startedVoice(h)
            #expect(h.model.isVoiceActive)
            try h.model.intentEndVoice()
            #expect(h.model.voiceConversation == nil)
            #expect(activity == [true, false])
            #expect(await eventually { h.system.ends.count == 1 })
        }

        @Test func sessionChoicesComeFromRecents() async throws {
            let h = try await connected(); defer { h.cleanup() }
            await h.model.refreshProjects()
            #expect(await eventually { !h.model.recentSessions.isEmpty })
            let choices = h.model.voiceSessionChoices()
            #expect(choices.map(\.storedID) == ["s-1"])
            #expect(choices.first?.title == "Untitled session")
            #expect(choices.first?.profile == h.model.selectedProfile)
        }

        @Test func targetsMapFromRequests() {
            #expect(
                AppModel.voiceTarget(for: .session(storedID: "a", title: "T", profile: "p"))
                    == .session(storedID: "a", title: "T", profile: "p"))
            guard case .new(nil, "p", _) = AppModel.voiceTarget(for: .new(profile: "p")) else {
                Issue.record("expected new target")
                return
            }
        }
    }
}
