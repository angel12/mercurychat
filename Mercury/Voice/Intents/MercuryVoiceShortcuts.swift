import AppIntents

/// Siri and Spotlight phrases for the voice intents (app target only).
struct MercuryVoiceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartVoiceConversationIntent(),
            phrases: [
                "Start a voice conversation in \(.applicationName)",
                "Talk to \(.applicationName)",
            ],
            shortTitle: "Start Voice",
            systemImageName: "waveform")
        AppShortcut(
            intent: SetVoiceMuteIntent(),
            phrases: [
                "\(\.$action) \(.applicationName)",
                "\(\.$action) \(.applicationName) voice",
                "Toggle mute in \(.applicationName)",
            ],
            shortTitle: "Mute Voice",
            systemImageName: "mic.slash")
        AppShortcut(
            intent: EndVoiceConversationIntent(),
            phrases: [
                "End \(.applicationName) voice",
                "End the voice conversation in \(.applicationName)",
                "Hang up \(.applicationName)",
            ],
            shortTitle: "End Voice",
            systemImageName: "phone.down")
    }
}
