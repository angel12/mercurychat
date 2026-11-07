import Foundation
import MercuryKit
@testable import MercuryVoiceEngine
import Testing

/// AppModel shows each voice conversation as a Live Activity whose Mute and
/// End (sub-project 5's intents) reach the conversation and its call
/// (sub-project 4).
extension SharedMeterTests {
    @MainActor
    @Suite("Voice Live Activity host")
    struct VoiceLiveActivityHostTests {

        struct Harness {
            let model: AppModel
            let calls: FakeVoiceCallSystem
            let activities: FakeLiveActivitySystem
            let cleanup: () -> Void
        }

        /// As `VoiceCallHostTests.connected`, with fake call and Live Activity systems.
        private func connected() async throws -> Harness {
            let script = MultiWindowChatTests.Script()
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
            let voices = ConversationRecorder()
            voices.script = { index, service in
                let answer = Fixtures.resumeResult(
                    runtimeID: "rt-v\(index)", storedID: "stored-v\(index)")
                service.enqueueCreate(answer)
                service.enqueueResume(answer)
            }
            model.makeVoiceController = { voices.make(connection: $0, profile: $1) }
            let calls = FakeVoiceCallSystem()
            model.voiceCallCenter = VoiceCallCenter(system: calls, sleep: { _ in })
            let activities = FakeLiveActivitySystem()
            model.voiceLiveActivity = VoiceLiveActivityCoordinator(system: activities)
            await model.connect(endpoint: endpoint, credentials: nil)
            let ready = await eventually {
                if case .ready = model.phase { return true }
                return false
            }
            try #require(ready)
            return Harness(
                model: model, calls: calls, activities: activities,
                cleanup: {
                    server.stop()
                    try? store.deleteToken(for: endpoint)
                })
        }

        private func newTarget() -> VoiceConversationHost.Target {
            .new(cwd: nil, profile: nil, request: UUID())
        }

        @Test func startingVoiceStartsOneActivity() async throws {
            let h = try await connected(); defer { h.cleanup() }
            await h.model.startVoice(newTarget())
            #expect(h.activities.starts.count == 1)
            #expect(h.activities.starts.first?.content.title == "Voice conversation")
            h.model.endVoice()
            await h.model.voiceLiveActivity.settled()
            #expect(h.activities.ends == ["activity-0"])
        }

        @Test func disconnectEndsTheActivity() async throws {
            let h = try await connected(); defer { h.cleanup() }
            await h.model.startVoice(newTarget())
            h.model.disconnect()
            await h.model.voiceLiveActivity.settled()
            #expect(h.activities.ends == ["activity-0"])
        }

        @Test func targetSwitchReplacesTheActivity() async throws {
            let h = try await connected(); defer { h.cleanup() }
            await h.model.startVoice(newTarget())
            await h.model.startVoice(newTarget())
            await h.model.voiceLiveActivity.settled()
            #expect(h.activities.starts.count == 2)
            #expect(h.activities.ends == ["activity-0"])
            h.model.endVoice()
        }

        @Test func muteIntentMutesTheConversationTheCallAndTheActivity() async throws {
            let h = try await connected(); defer { h.cleanup() }
            await h.model.startVoice(newTarget())
            let controller = try #require(h.model.voiceConversation?.controller)
            #expect(try await h.model.intentSetMute(true) == true)
            #expect(await eventually { controller.voiceState.muted })
            #expect(await eventually { h.calls.mutes.map(\.muted) == [true] })
            #expect(await eventually { h.activities.updates.last?.content.muted == true })
            #expect(try await h.model.intentSetMute(false) == false)
            #expect(await eventually { h.calls.mutes.map(\.muted) == [true, false] })
            #expect(await eventually { h.activities.updates.last?.content.muted == false })
            h.model.endVoice()
        }

        @Test func endIntentEndsTheCallAndTheActivity() async throws {
            let h = try await connected(); defer { h.cleanup() }
            await h.model.startVoice(newTarget())
            let call = try #require(h.calls.starts.first?.call)
            try h.model.intentEndVoice()
            #expect(h.model.voiceConversation == nil)
            #expect(await eventually { h.calls.ends == [call] })
            await h.model.voiceLiveActivity.settled()
            #expect(h.activities.ends == ["activity-0"])
        }

        @Test func intentsWithNoConversationSweepStaleActivities() async throws {
            let h = try await connected(); defer { h.cleanup() }
            await #expect(throws: VoiceIntentError.noConversation) {
                try await h.model.intentSetMute(true)
            }
            #expect(throws: VoiceIntentError.noConversation) {
                try h.model.intentEndVoice()
            }
            await h.model.voiceLiveActivity.settled()
            #expect(h.activities.endAllCount == 2)
            #expect(h.calls.starts.isEmpty)
        }

        @Test func launchSweepsStaleActivities() async throws {
            let h = try await connected(); defer { h.cleanup() }
            await h.model.autoConnectOnLaunch(lastServer: nil)
            await h.model.voiceLiveActivity.settled()
            #expect(h.activities.endAllCount == 1)
        }
    }
}
