import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The voice conversation on the lock screen and in the Dynamic Island
/// (spec §5). Mute and End run in the app (`LiveActivityIntent`).
struct VoiceLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceActivityAttributes.self) { context in
            VoiceActivityLockScreen(state: context.state, startedAt: context.attributes.startedAt)
                .padding(16)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.phase.systemImage)
                        .font(.title2)
                        .foregroundStyle(state.phase.tint)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 64)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VoiceActivityControls(state: state)
                }
            } compactLeading: {
                Image(systemName: "waveform")
                    .foregroundStyle(state.phase.tint)
                    .accessibilityLabel("Voice conversation")
            } compactTrailing: {
                Image(systemName: state.phase.systemImage)
                    .foregroundStyle(state.phase.tint)
                    .accessibilityLabel(state.phase.label)
            } minimal: {
                Image(systemName: state.phase.systemImage)
                    .foregroundStyle(state.phase.tint)
                    .accessibilityLabel(state.phase.label)
            }
            .keylineTint(state.phase.tint)
        }
    }
}

struct VoiceActivityLockScreen: View {
    let state: VoiceActivityContent
    let startedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(state.title).font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                Text(startedAt, style: .timer)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 72)
            }
            VoiceActivityControls(state: state)
        }
    }
}

struct VoiceActivityControls: View {
    let state: VoiceActivityContent

    var body: some View {
        HStack(spacing: 12) {
            Label(state.phase.label, systemImage: state.phase.systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(state.phase.tint)
                .lineLimit(1)
            Spacer(minLength: 8)
            // Explicit target, not a toggle: a stale state can't double-toggle.
            Button(intent: SetVoiceMuteIntent(action: state.muted ? .unmute : .mute)) {
                Image(systemName: state.muted ? "mic.slash.fill" : "mic.fill")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel(state.muted ? "Unmute" : "Mute")
            Button(role: .destructive, intent: EndVoiceConversationIntent()) {
                Image(systemName: "phone.down.fill")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(.red)
            .accessibilityLabel("End voice conversation")
        }
    }
}

extension VoiceActivityPhase {
    /// Needs input stands out; everything else uses the accent color.
    var tint: Color { needsAttention ? .orange : .accentColor }
}
