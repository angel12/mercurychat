import MercuryKit
import SwiftUI

/// Non-modal connection-state strip: reconnecting / disconnected / contract
/// drift. Hidden while everything is healthy.
struct ConnectionBannerView: View {
    @Environment(AppModel.self) private var model
    @State private var noticeVisible = true

    var body: some View {
        // Purely informational — never intercept touches meant for the UI
        // underneath (the composer lives at the same edge).
        banner.allowsHitTesting(false)
    }

    @ViewBuilder
    private var banner: some View {
        if let text = bannerText {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.callout)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .padding(.bottom, 72)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let notice = model.contractNotice, noticeVisible {
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
        default:
            return nil
        }
    }
}

#if os(macOS)
    struct SettingsView: View {
        @Environment(AppModel.self) private var model

        var body: some View {
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
                    Button("Disconnect", role: .destructive) { model.disconnect() }
                        .disabled(!model.isConnected)
                }
                Section("Diagnostics") {
                    LabeledContent("Connection phase", value: phaseDescription)
                    LabeledContent(
                        "Built against contract",
                        value: "v\(GatewayClient.builtAgainstDesktopContract)")
                }
            }
            .formStyle(.grouped)
            .frame(width: 440)
            .padding(.vertical)
        }

        private var phaseDescription: String {
            switch model.phase {
            case .stopped: return "stopped"
            case .connecting(let attempt): return "connecting (attempt \(attempt))"
            case .ready(let isReconnect): return isReconnect ? "ready (reconnected)" : "ready"
            case .disconnected(let reason): return "disconnected\(reason.map { ": \($0)" } ?? "")"
            case .authExpired: return "auth expired"
            }
        }
    }
#endif
