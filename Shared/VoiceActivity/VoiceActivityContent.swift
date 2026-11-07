import Foundation

/// The voice conversation's state as the Live Activity shows it
/// (sub-project 4). The in-app bar's status line is this phase's label,
/// so the bar and the Dynamic Island always agree.
enum VoiceActivityPhase: String, Codable, Hashable, Sendable {
    case listening, transcribing, thinking, speaking, waiting, needsInput, paused, muted,
        reconnecting

    var label: String {
        switch self {
        case .listening: "Listening"
        case .transcribing: "Transcribing"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .waiting: "Waiting"
        case .needsInput: "Needs your input"
        case .paused: "Paused"
        case .muted: "Muted"
        case .reconnecting: "Reconnecting"
        }
    }

    var systemImage: String {
        switch self {
        case .listening: "waveform"
        case .transcribing: "text.bubble"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        case .waiting: "hourglass"
        case .needsInput: "exclamationmark.bubble.fill"
        case .paused: "pause.fill"
        case .muted: "mic.slash.fill"
        case .reconnecting: "wifi.exclamationmark"
        }
    }

    /// A prompt is blocked on the user: drawn in the attention tint.
    var needsAttention: Bool { self == .needsInput }
}

/// The Live Activity's content state. The title lives here rather than in the
/// attributes because a session's title can arrive after the call starts.
struct VoiceActivityContent: Codable, Hashable, Sendable {
    var title: String
    var phase: VoiceActivityPhase
    var muted: Bool
}
