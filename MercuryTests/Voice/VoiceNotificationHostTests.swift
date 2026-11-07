import Foundation
import MercuryKit
@testable import MercuryVoiceEngine
import Testing

/// AppModel's voice prompt notifications and push ownership (sub-project 3).
extension SharedMeterTests {
    @MainActor
    @Suite("Voice notification host")
    struct VoiceNotificationHostTests {

        private func connected() async throws -> VoiceHostTests.Harness {
            try await VoiceHostTests().connected()
        }

        private func raiseApproval(_ controller: ConversationController) {
            controller.handle(event: GatewayEvent(
                type: GatewayEvent.Kind.approvalRequest, sessionID: "rt-v0",
                payload: Fixtures.approvalPayload(command: "ls", requestID: "req-1")))
        }

        @Test func backgroundPromptPostsAndActionApproves() async throws {
            let h = try await connected(); defer { h.cleanup() }
            let notes = FakeVoiceNotificationCenter()
            h.model.voicePromptNotifier = VoicePromptNotifier(
                center: notes, isAppActive: { false }, sleep: { _ in })
            await h.model.startVoice(.new(cwd: nil, profile: nil, request: UUID()))
            let controller = try #require(h.model.voiceConversation?.controller)
            raiseApproval(controller)
            #expect(await eventually { notes.added.count == 1 })
            let key = try #require(controller.frontPrompt?.key)
            h.model.handleVoiceNotification(promptKey: key, action: .approveOnce)
            let service = h.voices.launches[0].service
            #expect(await eventually { !service.promptResponses.isEmpty })
            let sent = try #require(service.promptResponses.first)
            switch sent {
            case .approvalRespond(_, let choice):
                #expect(choice == "once")
            case .requestAnswer(let params):
                #expect(params == .object(["id": .string("req-1"), "result": .object(["choice": .string("once")])]))
            case .clarifyRespond:
                Issue.record("unexpected clarify response")
            }
            h.model.endVoice()
        }

        @Test func staleActionDoesNotAnswer() async throws {
            let h = try await connected(); defer { h.cleanup() }
            await h.model.startVoice(.new(cwd: nil, profile: nil, request: UUID()))
            let controller = try #require(h.model.voiceConversation?.controller)
            raiseApproval(controller)
            h.model.handleVoiceNotification(promptKey: "approval-999", action: .deny)
            #expect(controller.approval != nil)
            #expect(!controller.promptResponseInFlight)
            #expect(h.voices.launches[0].service.promptResponses.isEmpty)
            h.model.endVoice()
        }

        @Test func endingVoiceWithdrawsNotifications() async throws {
            let h = try await connected(); defer { h.cleanup() }
            let notes = FakeVoiceNotificationCenter()
            h.model.voicePromptNotifier = VoicePromptNotifier(
                center: notes, isAppActive: { false }, sleep: { _ in })
            await h.model.startVoice(.new(cwd: nil, profile: nil, request: UUID()))
            let controller = try #require(h.model.voiceConversation?.controller)
            raiseApproval(controller)
            #expect(await eventually { notes.added.count == 1 })
            let key = try #require(controller.frontPrompt?.key)
            h.model.endVoice()
            #expect(await eventually {
                notes.removed.contains(VoicePromptNotifier.identifier(key))
            })
        }

        @Test func foregroundPushForLiveVoiceSessionIsSuppressed() async throws {
            let h = try await connected(); defer { h.cleanup() }
            await h.model.startVoice(.new(cwd: nil, profile: nil, request: UUID()))
            let stored = try #require(h.model.voiceConversation?.controller.storedSessionID)
            let route = PushTapRoute(serverKey: nil, profile: "default", sessionID: stored)
            #expect(h.model.shouldPresentPush(route, appActive: true) == false)
            #expect(h.model.shouldPresentPush(route, appActive: false) == true)
            // Another server's session with the same id is not this conversation.
            let elsewhere = PushTapRoute(serverKey: "http://other:1", profile: "default", sessionID: stored)
            #expect(h.model.shouldPresentPush(elsewhere, appActive: true) == true)
            h.model.endVoice()
        }

        @Test func launchSweepsStaleVoiceNotifications() async throws {
            let h = try await connected(); defer { h.cleanup() }
            let notes = FakeVoiceNotificationCenter()
            notes.deliveredNotes = [
                DeliveredNotification(id: "voice-prompt.approval-1", push: nil),
                DeliveredNotification(id: "push-1", push: nil),
            ]
            h.model.voicePromptNotifier = VoicePromptNotifier(
                center: notes, isAppActive: { true }, sleep: { _ in })
            await h.model.autoConnectOnLaunch(lastServer: nil)
            #expect(await eventually { notes.removed == ["voice-prompt.approval-1"] })
            #expect(notes.deliveredNotes.map(\.id) == ["push-1"])
        }
    }
}
