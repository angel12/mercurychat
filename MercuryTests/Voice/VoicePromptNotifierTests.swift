import Foundation
import MercuryKit
import Testing

@MainActor
final class FakeVoiceNotificationCenter: VoiceNotificationCenter {
    private(set) var added: [VoiceNotificationRequest] = []
    private(set) var removed: [String] = []
    var deliveredNotes: [DeliveredNotification] = []
    private(set) var authorizationRequests = 0
    /// When set, `add` suspends on it before landing (to model the add window).
    var addGate: (@MainActor () async -> Void)?
    func add(_ request: VoiceNotificationRequest) async {
        added.append(request)
        await addGate?()
        deliveredNotes.append(DeliveredNotification(id: request.id, push: nil))
    }
    func remove(ids: [String]) {
        removed += ids
        deliveredNotes.removeAll { ids.contains($0.id) }
    }
    func delivered() async -> [DeliveredNotification] { deliveredNotes }
    func requestAuthorizationIfUndetermined() async { authorizationRequests += 1 }
}

@MainActor
final class VoiceNotifierActiveFlag {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

@MainActor
@Suite("Voice prompt notifier")
struct VoicePromptNotifierTests {
    let approval = VoicePrompt(key: "approval-1", kind: .approval, pushRequestID: "req-1")
    let sudo = VoicePrompt(key: "credential-s1", kind: .sudo, pushRequestID: nil)

    func pushApproval(id: String, requestID: String?, session: String) -> DeliveredNotification {
        var block: [String: Any] = [
            "v": 1, "kind": "approval", "event_id": "e-\(id)", "profile": "coder", "session_id": session,
        ]
        if let requestID { block["request_id"] = requestID }
        return DeliveredNotification(id: id, push: PushPayload(userInfo: ["mercury": block]))
    }

    @Test func postsFixedTextWhenInactive() async {
        let center = FakeVoiceNotificationCenter()
        let notifier = VoicePromptNotifier(center: center, isAppActive: { false }, sleep: { _ in })
        notifier.promptChanged(approval, title: "Plan", storedSessionID: "s1")
        #expect(await eventually { center.added.count == 1 })
        let posted = center.added[0]
        #expect(posted.id == "voice-prompt.approval-1")
        #expect(posted.title == "Plan")
        #expect(posted.body == "Hermes needs your approval.")
        #expect(posted.categoryID == VoicePromptNotifier.categoryID)
        #expect(posted.promptKey == "approval-1")
    }

    @Test func credentialHasNoActions() async {
        let center = FakeVoiceNotificationCenter()
        let notifier = VoicePromptNotifier(center: center, isAppActive: { false }, sleep: { _ in })
        notifier.promptChanged(sudo, title: "Plan", storedSessionID: nil)
        #expect(await eventually { center.added.count == 1 })
        #expect(center.added[0].categoryID == nil)
        #expect(center.added[0].body == "Hermes needs your sudo password.")
    }

    @Test func activeAppPostsNothingUntilBackgrounded() async {
        let center = FakeVoiceNotificationCenter()
        let active = VoiceNotifierActiveFlag(true)
        let notifier = VoicePromptNotifier(center: center, isAppActive: { active.value }, sleep: { _ in })
        notifier.promptChanged(sudo, title: "Plan", storedSessionID: nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(center.added.isEmpty)
        active.value = false
        notifier.appEnteredBackground()
        #expect(await eventually { center.added.count == 1 })
        notifier.appEnteredBackground()  // no repost
        try? await Task.sleep(for: .milliseconds(50))
        #expect(center.added.count == 1)
    }

    @Test func settledPromptIsRemoved() async {
        let center = FakeVoiceNotificationCenter()
        let notifier = VoicePromptNotifier(center: center, isAppActive: { false }, sleep: { _ in })
        notifier.promptChanged(sudo, title: "Plan", storedSessionID: nil)
        notifier.promptChanged(nil, title: "Plan", storedSessionID: nil)
        #expect(await eventually { center.removed.contains("voice-prompt.credential-s1") })
    }

    @Test func foregroundRemovesPosted() async {
        let center = FakeVoiceNotificationCenter()
        let notifier = VoicePromptNotifier(center: center, isAppActive: { false }, sleep: { _ in })
        notifier.promptChanged(sudo, title: "Plan", storedSessionID: nil)
        #expect(await eventually { center.added.count == 1 })
        notifier.appBecameActive()
        #expect(await eventually { center.removed.contains("voice-prompt.credential-s1") })
    }

    @Test func conversationEndRemovesPosted() async {
        let center = FakeVoiceNotificationCenter()
        let notifier = VoicePromptNotifier(center: center, isAppActive: { false }, sleep: { _ in })
        notifier.promptChanged(sudo, title: "Plan", storedSessionID: nil)
        notifier.conversationEnded()
        #expect(await eventually { center.removed.contains("voice-prompt.credential-s1") })
    }

    @Test func sweepRemovesOnlyMatchingPushApprovals() async {
        let center = FakeVoiceNotificationCenter()
        center.deliveredNotes = [
            pushApproval(id: "match", requestID: "req-1", session: "s1"),
            pushApproval(id: "other-request", requestID: "req-2", session: "s1"),
            pushApproval(id: "other-session-no-id", requestID: nil, session: "s9"),
            DeliveredNotification(id: "not-push", push: nil),
        ]
        let notifier = VoicePromptNotifier(center: center, isAppActive: { false }, sleep: { _ in })
        notifier.promptChanged(approval, title: "Plan", storedSessionID: "s1")
        #expect(await eventually { center.removed.contains("match") })
        #expect(!center.removed.contains("other-request"))
        #expect(!center.removed.contains("other-session-no-id"))
        #expect(!center.removed.contains("not-push"))
    }

    @Test func sweepFallsBackToSessionWhenPushHasNoRequestID() async {
        let center = FakeVoiceNotificationCenter()
        center.deliveredNotes = [pushApproval(id: "same-session", requestID: nil, session: "s1")]
        let notifier = VoicePromptNotifier(center: center, isAppActive: { false }, sleep: { _ in })
        notifier.promptChanged(approval, title: "Plan", storedSessionID: "s1")
        #expect(await eventually { center.removed.contains("same-session") })
    }

    @Test func settlingInsideAddWindowLeavesNothingBehind() async {
        let center = FakeVoiceNotificationCenter()
        let release = VoiceNotifierActiveFlag(false)
        center.addGate = { while !release.value { try? await Task.sleep(for: .milliseconds(5)) } }
        let notifier = VoicePromptNotifier(center: center, isAppActive: { false }, sleep: { _ in })
        notifier.promptChanged(sudo, title: "Plan", storedSessionID: nil)
        #expect(await eventually { center.added.count == 1 })
        notifier.promptChanged(nil, title: "Plan", storedSessionID: nil)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(center.removed.isEmpty)  // remove waits for the add
        release.value = true
        #expect(await eventually { center.removed == ["voice-prompt.credential-s1"] })
        #expect(center.deliveredNotes.isEmpty)
    }

    @Test func foregroundInsideAddWindowLeavesNothingBehind() async {
        let center = FakeVoiceNotificationCenter()
        let release = VoiceNotifierActiveFlag(false)
        center.addGate = { while !release.value { try? await Task.sleep(for: .milliseconds(5)) } }
        let notifier = VoicePromptNotifier(center: center, isAppActive: { false }, sleep: { _ in })
        notifier.promptChanged(sudo, title: "Plan", storedSessionID: nil)
        #expect(await eventually { center.added.count == 1 })
        notifier.appBecameActive()
        release.value = true
        #expect(await eventually { center.removed.contains("voice-prompt.credential-s1") })
        #expect(center.deliveredNotes.isEmpty)
    }

    @Test func keyChangeWithdrawsOldAndPostsNew() async {
        let center = FakeVoiceNotificationCenter()
        let notifier = VoicePromptNotifier(center: center, isAppActive: { false }, sleep: { _ in })
        notifier.promptChanged(sudo, title: "Plan", storedSessionID: nil)
        #expect(await eventually { center.added.count == 1 })
        notifier.promptChanged(approval, title: "Plan", storedSessionID: "s1")
        #expect(await eventually { center.added.count == 2 && center.removed.contains("voice-prompt.credential-s1") })
        #expect(center.added[1].id == "voice-prompt.approval-1")
    }

    @Test func repeatedSameKeyPostsOnce() async {
        let center = FakeVoiceNotificationCenter()
        let notifier = VoicePromptNotifier(center: center, isAppActive: { false }, sleep: { _ in })
        notifier.promptChanged(sudo, title: "Plan", storedSessionID: nil)
        notifier.promptChanged(sudo, title: "Plan", storedSessionID: nil)
        notifier.promptChanged(sudo, title: "Plan", storedSessionID: nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(center.added.count == 1)
    }

    @Test func actionIdentifiersMap() {
        #expect(VoicePromptNotifier.action(forIdentifier: VoicePromptNotifier.approveActionID) == .approveOnce)
        #expect(VoicePromptNotifier.action(forIdentifier: VoicePromptNotifier.denyActionID) == .deny)
        #expect(VoicePromptNotifier.action(forIdentifier: "com.apple.UNNotificationDefaultActionIdentifier") == .open)
    }
}
