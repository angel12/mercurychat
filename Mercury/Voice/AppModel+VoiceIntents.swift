import Foundation
import MercuryKit

/// Shortcuts, Siri and the macOS hotkey drive the voice conversation here
/// (sub-project 5). Mute goes through the controller, so on iOS it reaches
/// CallKit by the same `onMuteChanged → syncMute` path as the mute button.
extension AppModel: VoiceIntentActions {
    var isVoiceActive: Bool { voiceConversation != nil }

    func intentStartVoice(_ request: VoiceStartRequest) async throws {
        guard await waitForConnection(timeout: voiceIntentConnectTimeout) else {
            throw VoiceIntentError.notConnected
        }
        openVoiceFromSystem(Self.voiceTarget(for: request))
    }

    func intentSetMute(_ target: Bool?) async throws -> Bool {
        guard let controller = voiceConversation?.controller else {
            // A Live Activity left by a conversation that's gone: clear it.
            voiceLiveActivity.endAll()
            throw VoiceIntentError.noConversation
        }
        guard let muted = await controller.applyMute(target) else {
            throw VoiceIntentError.voiceNotReady
        }
        return muted
    }

    func intentEndVoice() throws {
        guard voiceConversation != nil else {
            voiceLiveActivity.endAll()
            throw VoiceIntentError.noConversation
        }
        endVoice()
    }

    func voiceSessionChoices() -> [VoiceSessionEntity] {
        recentSessions.map { session in
            let title = session.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled session"
            return VoiceSessionEntity(
                storedID: session.storedID, profile: session.profile ?? selectedProfile,
                title: title)
        }
    }

    func voiceProfileChoices() -> [VoiceProfileEntity] {
        profiles.map { VoiceProfileEntity(name: $0.name, displayName: $0.displayName) }
    }

    static func voiceTarget(for request: VoiceStartRequest) -> VoiceConversationHost.Target {
        switch request {
        case .session(let storedID, let title, let profile):
            .session(storedID: storedID, title: title, profile: profile)
        case .new(let profile):
            .new(cwd: nil, profile: profile, request: UUID())
        }
    }
}
