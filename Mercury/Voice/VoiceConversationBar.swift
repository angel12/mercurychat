import SwiftUI

/// The "In voice conversation" bar, shown over any other screen while the
/// app's voice conversation keeps running.
struct VoiceConversationBar: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowNavigation.self) private var navigation
    let host: VoiceConversationHost

    private var controller: ConversationController { host.controller }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(statusWord).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                controller.toggleMute()
            } label: {
                Image(systemName: controller.voiceState.muted ? "mic.slash.fill" : "mic.fill")
            }
            .accessibilityLabel(controller.voiceState.muted ? "Unmute" : "Mute")
            Button {
                navigation.route = .voice
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .accessibilityLabel("Return to voice conversation")
            Button(role: .destructive) {
                model.endVoice()
            } label: {
                Image(systemName: "phone.down.fill")
            }
            .accessibilityLabel("End voice conversation")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        if let title = controller.sessionTitle, !title.isEmpty { return title }
        if case .session(_, let title?, _) = host.target, !title.isEmpty { return title }
        return "Voice conversation"
    }

    private var statusWord: String {
        if controller.isWaitingForTurn { return "Waiting" }
        if controller.voiceState.paused { return "Paused" }
        if controller.voiceState.muted { return "Muted" }
        switch controller.voiceState.status {
        case .idle: return "Paused"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        }
    }
}
