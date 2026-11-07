#if os(iOS)
    import AppIntents

    // The Live Activity's Mute and End buttons (sub-project 4). As
    // LiveActivityIntents they run in the app's process, which stays alive for
    // the whole call, where `VoiceIntentBridge.shared` is set. Compiled into
    // the app and the MercuryWidgets extension, so both see the conformance.
    extension SetVoiceMuteIntent: LiveActivityIntent {}
    extension EndVoiceConversationIntent: LiveActivityIntent {}
#endif
