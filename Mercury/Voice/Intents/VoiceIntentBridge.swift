import Foundation

// Shared with sub-project 4 (Live Activity): this folder must not import
// MercuryKit or name AppModel, so a widget extension can compile it.

/// What "Start voice conversation" asks for.
enum VoiceStartRequest: Equatable, Sendable {
    /// Resume a stored session.
    case session(storedID: String, title: String?, profile: String?)
    /// A new conversation; nil profile = the app's selected profile.
    case new(profile: String?)
}

enum VoiceIntentError: Error, Equatable, LocalizedError {
    case noConversation
    case notConnected
    case appNotReady
    case voiceNotReady

    var errorDescription: String? {
        switch self {
        case .noConversation: "No voice conversation is running."
        case .notConnected: "Mercury isn't connected to a server."
        case .appNotReady: "Mercury isn't ready yet. Try again in a moment."
        case .voiceNotReady: "The voice conversation is still starting."
        }
    }
}

/// The app side of the voice intents (AppModel in the app, a fake in tests).
@MainActor
protocol VoiceIntentActions: AnyObject {
    var isVoiceActive: Bool { get }
    func intentStartVoice(_ request: VoiceStartRequest) async throws
    /// `target` nil toggles. Returns the muted state afterward.
    func intentSetMute(_ target: Bool?) async throws -> Bool
    func intentEndVoice() throws
    func voiceSessionChoices() -> [VoiceSessionEntity]
    func voiceProfileChoices() -> [VoiceProfileEntity]
}

/// Where intents find the app. The app sets `shared` at launch.
@MainActor
enum VoiceIntentBridge {
    static var shared: (any VoiceIntentActions)?

    static func start(_ request: VoiceStartRequest) async throws {
        try await start(request, on: shared)
    }

    static func setMute(_ action: VoiceMuteAction) async throws -> Bool {
        try await setMute(action, on: shared)
    }

    static func end() throws {
        try end(on: shared)
    }

    static func sessionChoices() -> [VoiceSessionEntity] { shared?.voiceSessionChoices() ?? [] }
    static func profileChoices() -> [VoiceProfileEntity] { shared?.voiceProfileChoices() ?? [] }

    static func start(_ request: VoiceStartRequest, on actions: (any VoiceIntentActions)?)
        async throws
    {
        guard let actions else { throw VoiceIntentError.appNotReady }
        try await actions.intentStartVoice(request)
    }

    static func setMute(_ action: VoiceMuteAction, on actions: (any VoiceIntentActions)?)
        async throws -> Bool
    {
        guard let actions else { throw VoiceIntentError.appNotReady }
        return try await actions.intentSetMute(action.target)
    }

    static func end(on actions: (any VoiceIntentActions)?) throws {
        guard let actions else { throw VoiceIntentError.appNotReady }
        try actions.intentEndVoice()
    }
}
