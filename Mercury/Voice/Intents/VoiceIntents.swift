import AppIntents
import Foundation

/// Starts (or shows) the voice conversation. Opens the app: the mic and, on
/// iOS, the CallKit call start reliably only from the foreground.
struct StartVoiceConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Voice Conversation"
    static let description = IntentDescription(
        "Starts a Mercury voice conversation: resumes a session, or starts a new one in a profile.")
    static let openAppWhenRun = true

    @Parameter(title: "Session", description: "A recent session to resume.")
    var session: VoiceSessionEntity?

    @Parameter(title: "Profile", description: "The profile for a new conversation.")
    var profile: VoiceProfileEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Start a voice conversation") {
            \.$session
            \.$profile
        }
    }

    init() {}

    init(session: VoiceSessionEntity? = nil, profile: VoiceProfileEntity? = nil) {
        self.session = session
        self.profile = profile
    }

    /// A chosen session wins; otherwise a new conversation in `profile`.
    static func request(session: VoiceSessionEntity?, profile: VoiceProfileEntity?)
        -> VoiceStartRequest
    {
        if let session {
            return .session(storedID: session.storedID, title: session.title, profile: session.profile)
        }
        return .new(profile: profile?.name)
    }

    func perform() async throws -> some IntentResult {
        try await VoiceIntentBridge.start(Self.request(session: session, profile: profile))
        return .result()
    }
}

/// Mutes, unmutes or toggles the running conversation without opening the app.
struct SetVoiceMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute Voice Conversation"
    static let description = IntentDescription(
        "Mutes, unmutes or toggles the microphone of the running Mercury voice conversation.")
    static let openAppWhenRun = false

    @Parameter(title: "Action", default: .toggle)
    var action: VoiceMuteAction

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) the voice conversation")
    }

    init() {}

    init(action: VoiceMuteAction) {
        self.action = action
    }

    static func dialogText(muted: Bool) -> String { muted ? "Muted" : "Unmuted" }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let muted = try await VoiceIntentBridge.setMute(action)
        return .result(dialog: "\(Self.dialogText(muted: muted))")
    }
}

/// Ends the running conversation without opening the app.
struct EndVoiceConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "End Voice Conversation"
    static let description = IntentDescription("Ends the running Mercury voice conversation.")
    static let openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult {
        try await VoiceIntentBridge.end()
        return .result()
    }
}
