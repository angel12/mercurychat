import ChatCore
import MercuryKit
import MercuryVoiceEngine
import SwiftUI

/// Non-modal connection-state strip: reconnecting / disconnected / contract
/// drift. Hidden while everything is healthy.
struct ConnectionBannerView: View {
    @Environment(AppModel.self) private var model
    @State private var noticeVisible = true

    var body: some View {
        if case .unreachable = model.phase {
            // The one interactive banner: retries have given up and the only
            // way back is an explicit poke (or a network-path change).
            unreachableBanner
        } else {
            // Purely informational — never intercept touches meant for the UI
            // underneath (the composer lives at the same edge).
            banner.allowsHitTesting(false)
        }
    }

    private var unreachableBanner: some View {
        HStack(spacing: 10) {
            Text("Server unreachable").font(.callout)
            Button("Retry") { model.retryConnection() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .padding(.bottom, 72)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder
    private var banner: some View {
        if let text = bannerText {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                // Hard cap: a verbose close reason must never take over the
                // screen — the full text lives in Settings > Diagnostics.
                Text(text).font(.callout).lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .padding(.bottom, 72)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let notice = model.contractNotice ?? model.keychainNotice, noticeVisible {
            Text(notice)
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.yellow.opacity(0.9), in: Capsule())
                .padding(.bottom, 72)
                .task {
                    try? await Task.sleep(for: .seconds(8))
                    withAnimation { noticeVisible = false }
                }
        }
    }

    private var bannerText: String? {
        switch model.phase {
        case .connecting(let attempt) where attempt > 0:
            return "Reconnecting…"
        case .disconnected(let reason):
            return reason.map { "Disconnected: \($0)" } ?? "Disconnected — retrying…"
        case .refused(let reason):
            return reason.map { "Refused: \($0)" } ?? "The server refused this connection."
        default:
            return nil
        }
    }
}

#if os(macOS)
    struct SettingsView: View {
        @Environment(AppModel.self) private var model
        var devices = AudioDeviceCatalog.shared
        @AppStorage(CuePreference.key) private var cuesEnabled = true

        var body: some View {
            TabView {
                generalTab
                    .tabItem { Label("General", systemImage: "gearshape") }
                voiceTab
                    .tabItem { Label("Voice", systemImage: "waveform") }
            }
            .frame(width: 440)
        }

        private var voiceTab: some View {
            Form {
                Section("Audio") {
                    AudioInputPicker(devices: devices)
                    AudioOutputPicker(devices: devices)
                }
                Section("Listening") {
                    TurnSilenceSlider()
                    BargeInToggle()
                }
                Section("Sounds") {
                    Toggle("Conversation cues", isOn: $cuesEnabled)
                    Text(
                        "A short blip confirms your speech was captured; a soft tick every few seconds means the agent is still thinking."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.vertical)
            .onAppear { devices.refresh() }
        }

        private var generalTab: some View {
            Form {
                Section("Connection") {
                    LabeledContent("Server", value: model.endpoint?.displayName ?? "Not connected")
                    if let status = model.serverStatus {
                        LabeledContent("Backend version", value: status.version ?? "unknown")
                        LabeledContent(
                            "Auth", value: status.authRequired ? "Gated" : "Token (loopback)")
                    }
                    if let notice = model.contractNotice {
                        Text(notice).font(.callout).foregroundStyle(.orange)
                    }
                    if let notice = model.keychainNotice {
                        Text(notice).font(.callout).foregroundStyle(.orange)
                    }
                    Button("Disconnect", role: .destructive) { model.disconnect() }
                        .disabled(!model.isConnected)
                }
                Section("Diagnostics") {
                    LabeledContent("Connection phase", value: phaseDescription)
                    LabeledContent(
                        "Needs contract",
                        value: "v\(AppModel.contractRequirement.minimum) or newer")
                    LabeledContent("Bot Mode (profiles RPC)", value: botModeDescription)
                }
                Section("About") {
                    Link("Privacy Policy", destination: MercuryLinks.privacyPolicy)
                }
            }
            .formStyle(.grouped)
            .padding(.vertical)
        }

        private var botModeDescription: String {
            switch model.botModeSupported {
            case true?: return "supported"
            case false?: return "not supported (update the backend)"
            case nil: return "unknown"
            }
        }

        private var phaseDescription: String {
            switch model.phase {
            case .stopped: return "stopped"
            case .connecting(let attempt): return "connecting (attempt \(attempt))"
            case .ready(let isReconnect): return isReconnect ? "ready (reconnected)" : "ready"
            case .disconnected(let reason): return "disconnected\(reason.map { ": \($0)" } ?? "")"
            case .authExpired: return "auth expired"
            case .refused(let reason): return "refused\(reason.map { ": \($0)" } ?? "")"
            case .unreachable(let reason):
                return "unreachable\(reason.map { ": \($0)" } ?? "")"
            }
        }
    }
#endif
