import AppIntents
import SwiftUI
import WidgetKit

/// One tap starts a voice conversation (spec §4). Static: nothing to refresh.
struct VoiceQuickStartWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.spencermcguire.mercurychat.voice-quick-start",
            provider: VoiceQuickStartProvider()
        ) { _ in
            VoiceQuickStartView()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Talk to Hermes")
        .description("Start a voice conversation with one tap.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct VoiceQuickStartEntry: TimelineEntry {
    let date: Date
}

struct VoiceQuickStartProvider: TimelineProvider {
    func placeholder(in context: Context) -> VoiceQuickStartEntry { VoiceQuickStartEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (VoiceQuickStartEntry) -> Void) {
        completion(VoiceQuickStartEntry(date: .now))
    }
    func getTimeline(
        in context: Context, completion: @escaping (Timeline<VoiceQuickStartEntry>) -> Void
    ) {
        completion(Timeline(entries: [VoiceQuickStartEntry(date: .now)], policy: .never))
    }
}

struct VoiceQuickStartView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Button(intent: StartVoiceConversationIntent()) {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "waveform").font(.title2)
                }
            case .accessoryRectangular:
                Label("Talk to Hermes", systemImage: "waveform")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            default:
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                    Spacer(minLength: 0)
                    Text("Talk to Hermes").font(.headline)
                    Text("Mercury Chat").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Talk to Hermes")
    }
}

/// Control Center, the Lock Screen and the Action button (iOS 18).
@available(iOS 18.0, *)
struct VoiceQuickStartControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.spencermcguire.mercurychat.voice-start-control") {
            ControlWidgetButton(action: StartVoiceConversationIntent()) {
                Label("Talk to Hermes", systemImage: "waveform")
            }
        }
        .displayName("Talk to Hermes")
        .description("Start a voice conversation in Mercury Chat.")
    }
}
