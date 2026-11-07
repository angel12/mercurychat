import Foundation
import Testing

/// Records what the voice intents asked the app to do.
@MainActor
final class FakeVoiceIntentActions: VoiceIntentActions {
    var isVoiceActive = true
    var starts: [VoiceStartRequest] = []
    var muteTargets: [Bool?] = []
    var ends = 0
    var mutedAfter = true
    var startError: VoiceIntentError?
    var sessions: [VoiceSessionEntity] = []
    var profiles: [VoiceProfileEntity] = []

    func intentStartVoice(_ request: VoiceStartRequest) async throws {
        if let startError { throw startError }
        starts.append(request)
    }
    func intentSetMute(_ target: Bool?) async throws -> Bool {
        muteTargets.append(target)
        return mutedAfter
    }
    func intentEndVoice() throws { ends += 1 }
    func voiceSessionChoices() -> [VoiceSessionEntity] { sessions }
    func voiceProfileChoices() -> [VoiceProfileEntity] { profiles }
}

@MainActor
@Suite("Voice intents")
struct VoiceIntentTests {
    private let session = VoiceSessionEntity(storedID: "s1", profile: "work", title: "Plan")
    private let profile = VoiceProfileEntity(name: "home", displayName: "Home")

    @Test func sessionWinsOverProfile() {
        #expect(
            StartVoiceConversationIntent.request(session: session, profile: profile)
                == .session(storedID: "s1", title: "Plan", profile: "work"))
    }

    @Test func profileAloneStartsNewConversationInIt() {
        #expect(StartVoiceConversationIntent.request(session: nil, profile: profile) == .new(profile: "home"))
        #expect(StartVoiceConversationIntent.request(session: nil, profile: nil) == .new(profile: nil))
    }

    @Test func muteActionTargets() {
        #expect(VoiceMuteAction.toggle.target == nil)
        #expect(VoiceMuteAction.mute.target == true)
        #expect(VoiceMuteAction.unmute.target == false)
    }

    @Test func bridgeForwardsToActions() async throws {
        let fake = FakeVoiceIntentActions()
        try await VoiceIntentBridge.start(.new(profile: "p"), on: fake)
        fake.mutedAfter = false
        let muted = try await VoiceIntentBridge.setMute(.unmute, on: fake)
        try VoiceIntentBridge.end(on: fake)
        #expect(fake.starts == [.new(profile: "p")])
        #expect(fake.muteTargets == [false])
        #expect(muted == false)
        #expect(fake.ends == 1)
    }

    @Test func bridgeWithoutAppIsNotReady() async {
        await #expect(throws: VoiceIntentError.appNotReady) {
            try await VoiceIntentBridge.start(.new(profile: nil), on: nil)
        }
        await #expect(throws: VoiceIntentError.appNotReady) {
            _ = try await VoiceIntentBridge.setMute(.toggle, on: nil)
        }
        #expect(throws: VoiceIntentError.appNotReady) { try VoiceIntentBridge.end(on: nil) }
    }

    @Test func startErrorsPropagate() async {
        let fake = FakeVoiceIntentActions()
        fake.startError = .notConnected
        await #expect(throws: VoiceIntentError.notConnected) {
            try await VoiceIntentBridge.start(.new(profile: nil), on: fake)
        }
    }

    @Test func sessionIDRoundTrips() throws {
        let plain = VoiceSessionEntity(storedID: "abc", profile: nil, title: "T")
        #expect(plain.id == "|abc")
        let parsed = try #require(VoiceSessionEntity.parse(id: plain.id))
        #expect(parsed.storedID == "abc")
        #expect(parsed.profile == nil)
        let barred = try #require(VoiceSessionEntity.parse(id: "work|a|b"))
        #expect(barred.storedID == "a|b")
        #expect(barred.profile == "work")
        #expect(VoiceSessionEntity.parse(id: "nobar") == nil)
        #expect(VoiceSessionEntity.parse(id: "work|") == nil)
    }

    @Test func resolveUsesKnownTitlesAndKeepsUnknownIDs() {
        let resolved = VoiceSessionQuery.resolve(
            [session.id, "|offline", "garbage"], choices: [session])
        #expect(resolved.map(\.title) == ["Plan", "Session"])
        #expect(resolved.map(\.storedID) == ["s1", "offline"])
        #expect(resolved.last?.profile == nil)
    }

    @Test func profileQueryResolvesNamesOffline() {
        let resolved = VoiceProfileQuery.resolve(["home", "gone"], choices: [profile])
        #expect(resolved.map(\.displayName) == ["Home", "gone"])
    }

    @Test func muteDialog() {
        #expect(SetVoiceMuteIntent.dialogText(muted: true) == "Muted")
        #expect(SetVoiceMuteIntent.dialogText(muted: false) == "Unmuted")
    }
}
