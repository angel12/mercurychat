import Foundation
import MercuryKit
@testable import MercuryVoiceEngine
import Testing

/// AppModel runs each voice conversation as a system call (sub-project 3).
extension SharedMeterTests {
    @MainActor
    @Suite("Voice call host")
    struct VoiceCallHostTests {

        struct Harness {
            let model: AppModel
            let server: HermesTestServer
            let voices: ConversationRecorder
            let cleanup: () -> Void
        }

        /// As `VoiceHostTests.connected`; `failOpen` leaves the create
        /// unanswered so the session open fails.
        private func connected(failOpen: Bool = false) async throws -> Harness {
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
                guard !failOpen else { return }
                let answer = Fixtures.resumeResult(
                    runtimeID: "rt-v\(index)", storedID: "stored-v\(index)")
                service.enqueueCreate(answer)
                service.enqueueResume(answer)
            }
            model.makeVoiceController = { voices.make(connection: $0, profile: $1) }
            await model.connect(endpoint: endpoint, credentials: nil)
            let ready = await eventually {
                if case .ready = model.phase { return true }
                return false
            }
            try #require(ready)
            return Harness(
                model: model, server: server, voices: voices,
                cleanup: {
                    server.stop()
                    try? store.deleteToken(for: endpoint)
                })
        }

        @Test func startingVoiceStartsACallAndWaitsForAudio() async throws {
            let h = try await connected(); defer { h.cleanup() }
            let system = FakeVoiceCallSystem()
            h.model.voiceCallCenter = VoiceCallCenter(system: system, sleep: neverSleep)
            let start = Task { await h.model.startVoice(.new(cwd: nil, profile: nil, request: UUID())) }
            #expect(await eventually { system.starts.count == 1 })
            #expect(system.starts.first?.name == "Voice conversation")
            try await Task.sleep(for: .milliseconds(200))
            #expect(h.voices.launches[0].recorder.startCalls == 0)
            h.model.voiceCallCenter.systemDidActivateAudio()
            await start.value
            #expect(await eventually { h.voices.launches[0].recorder.startCalls > 0 })
            h.model.endVoice()
        }

        @Test func endingVoiceEndsTheCall() async throws {
            let h = try await connected(); defer { h.cleanup() }
            let system = FakeVoiceCallSystem()
            h.model.voiceCallCenter = VoiceCallCenter(system: system, sleep: { _ in })
            await h.model.startVoice(.new(cwd: nil, profile: nil, request: UUID()))
            let call = try #require(system.starts.first?.call)
            h.model.endVoice()
            #expect(await eventually { system.ends == [call] })
        }

        @Test func systemEndEndsTheConversation() async throws {
            let h = try await connected(); defer { h.cleanup() }
            let system = FakeVoiceCallSystem()
            h.model.voiceCallCenter = VoiceCallCenter(system: system, sleep: { _ in })
            await h.model.startVoice(.new(cwd: nil, profile: nil, request: UUID()))
            let call = try #require(system.starts.first?.call)
            h.model.voiceCallCenter.systemDidEnd(call)
            #expect(h.model.voiceConversation == nil)
            try await Task.sleep(for: .milliseconds(50))
            #expect(system.ends.isEmpty)
        }

        @Test func muteSyncsBothWays() async throws {
            let h = try await connected(); defer { h.cleanup() }
            let system = FakeVoiceCallSystem()
            h.model.voiceCallCenter = VoiceCallCenter(system: system, sleep: { _ in })
            await h.model.startVoice(.new(cwd: nil, profile: nil, request: UUID()))
            let controller = try #require(h.model.voiceConversation?.controller)
            let call = try #require(system.starts.first?.call)
            controller.toggleMute()
            #expect(await eventually { system.mutes.map(\.muted) == [true] })
            h.model.voiceCallCenter.systemDidSetMuted(call, muted: true)  // echo
            h.model.voiceCallCenter.systemDidSetMuted(call, muted: false)  // lock screen
            #expect(await eventually { !controller.voiceState.muted })
            try await Task.sleep(for: .milliseconds(100))
            #expect(system.mutes.count == 1)
            h.model.endVoice()
        }

        @Test func timedOutCallShowsFallbackNotice() async throws {
            let h = try await connected(); defer { h.cleanup() }
            h.model.voiceCallCenter = VoiceCallCenter(
                system: FakeVoiceCallSystem(), sleep: { _ in })
            await h.model.startVoice(.new(cwd: nil, profile: nil, request: UUID()))
            #expect(
                h.model.voiceConversation?.controller.notice
                    == ConversationController.callUnavailableNotice)
            h.model.endVoice()
        }

        @Test func setupErrorReportsTheCallFailed() async throws {
            let h = try await connected(failOpen: true); defer { h.cleanup() }
            let system = FakeVoiceCallSystem()
            h.model.voiceCallCenter = VoiceCallCenter(system: system, sleep: { _ in })
            await h.model.startVoice(.new(cwd: nil, profile: nil, request: UUID()))
            #expect(await eventually { system.reportedEnded.first?.failed == true })
            h.model.endVoice()
        }
    }
}
