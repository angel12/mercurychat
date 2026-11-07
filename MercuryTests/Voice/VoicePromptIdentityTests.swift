import Foundation
import MercuryKit
@testable import MercuryVoiceEngine
import Testing

extension SharedMeterTests {
    @MainActor
    @Suite("Voice prompt identity")
    struct VoicePromptIdentityTests {
        func begun() -> (ConversationController, ConversationRecorder) {
            let voices = ConversationRecorder()
            voices.script = { _, service in
                service.enqueueCreate(Fixtures.resumeResult(runtimeID: "rt-a", storedID: "stored-a"))
            }
            let controller = voices.make(connection: makeUndialedConnection(), profile: "coder")
            return (controller, voices)
        }

        @Test func approvalThenSettleReportsFrontPrompt() async throws {
            let (controller, _) = begun()
            var seen: [VoicePrompt?] = []
            controller.onFrontPromptChanged = { seen.append($0) }
            await controller.begin(mode: .create(cwd: nil, title: nil))
            controller.handle(event: GatewayEvent(
                type: GatewayEvent.Kind.approvalRequest, sessionID: "rt-a",
                payload: Fixtures.approvalPayload(command: "ls", requestID: "req-1")))
            let prompt = try #require(controller.frontPrompt)
            #expect(prompt.kind == .approval)
            #expect(prompt.pushRequestID == "req-1")
            #expect(prompt.key.hasPrefix("approval-"))
            #expect(prompt.body == "Hermes needs your approval.")
            controller.approval = nil
            #expect(controller.frontPrompt == nil)
            #expect(seen.count == 2)
            #expect(seen.last! == nil)
            await controller.teardown()
        }

        @Test func approvalKeysDifferAcrossConversations() async throws {
            let (first, _) = begun()
            let (second, _) = begun()
            await first.begin(mode: .create(cwd: nil, title: nil))
            await second.begin(mode: .create(cwd: nil, title: nil))
            for controller in [first, second] {
                controller.handle(event: GatewayEvent(
                    type: GatewayEvent.Kind.approvalRequest, sessionID: "rt-a",
                    payload: Fixtures.approvalPayload(command: "ls", requestID: "req-1")))
            }
            let a = try #require(first.frontPrompt?.key)
            let b = try #require(second.frontPrompt?.key)
            #expect(a.hasPrefix("approval-") && b.hasPrefix("approval-"))
            #expect(a != b)
            await first.teardown()
            await second.teardown()
        }

        @Test func clarifyKeyUsesRequestID() async {
            let (controller, _) = begun()
            await controller.begin(mode: .create(cwd: nil, title: nil))
            controller.handle(event: GatewayEvent(
                type: GatewayEvent.Kind.clarifyRequest, sessionID: "rt-a",
                payload: Fixtures.clarifyPayload(requestID: "c-1", question: "Which?")))
            #expect(controller.frontPrompt?.key == "clarify-c-1")
            #expect(controller.frontPrompt?.body == "Hermes has a question for you.")
            await controller.teardown()
        }

        @Test func createdSessionReportsActivityOnce() async {
            let (controller, _) = begun()
            var claims: [String] = []
            var profiles: [String?] = []
            controller.onSessionActivity = { id, profile in
                claims.append(id)
                profiles.append(profile)
            }
            await controller.begin(mode: .create(cwd: nil, title: nil))
            #expect(claims == ["stored-a"])
            #expect(profiles == ["coder"])
            #expect(controller.storedSessionID == "stored-a")
            await controller.teardown()
        }

        @Test func resumedSessionClaimsOnlyOnSubmit() async throws {
            let service = ScriptedSessionService()
            service.enqueueResume(Fixtures.resumeResult(runtimeID: "rt-b", storedID: "stored-b"))
            let controller = ConversationController(
                connection: makeUndialedConnection(), profile: nil,
                sessionService: service, speech: RecordingSpeech(),
                submitPrompt: { _, _, _, _ in PromptSubmission(status: "streaming") })
            var claims: [String] = []
            controller.onSessionActivity = { id, _ in claims.append(id) }
            try await controller.openSession(mode: .resume(storedID: "stored-b"))
            #expect(claims.isEmpty)
            controller.submitTextPrompt("hello")
            #expect(await eventually { claims == ["stored-b"] })
            await controller.teardown()
        }
    }
}
