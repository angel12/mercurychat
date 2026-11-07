#if os(iOS)
    import ActivityKit
    import Foundation

    /// The voice conversation's Live Activity. `startedAt` drives the timer;
    /// everything that changes lives in the content state.
    struct VoiceActivityAttributes: ActivityAttributes {
        typealias ContentState = VoiceActivityContent
        var startedAt: Date
    }
#endif
