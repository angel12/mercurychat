import MercuryKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isConnected {
            ConnectedView()
        } else {
            ConnectView()
        }
    }
}

/// The connected shell: split view on regular widths (iPad/Mac/Vision),
/// drill-in stack on iPhone.
struct ConnectedView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationTitle(model.endpoint?.displayName ?? "Mercury Chat")
                #if os(macOS)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300)
                #endif
        } detail: {
            switch model.route {
            case .session(let session):
                ChatView(mode: .resume(session), sessionKey: session.storedID)
                    .id(session.storedID)
            case .newSession(let cwd):
                ChatView(mode: .create(cwd: cwd, title: nil), sessionKey: "new-\(cwd ?? "")")
                    .id("new-session-\(cwd ?? "")")
            case .botChat(let target):
                ChatView(
                    mode: botChatMode(target),
                    sessionKey: "bot-\(target.profile)-\(target.storedID ?? "new")",
                    botContext: .init(
                        profile: target.profile, displayTitle: target.displayTitle)
                )
                .id("bot-\(target.profile)-\(target.storedID ?? "new")")
            case nil:
                ContentUnavailableView(
                    "No Session Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick a session from the sidebar or start a new one."))
            }
        }
        .overlay(alignment: .bottom) {
            ConnectionBannerView()
        }
    }

    /// Resume the canonical Bot Chat's server-resolved tip, or create it —
    /// titled exactly "Bot Chat", the NAME that makes it canonical (the
    /// gateway's registry resolves by that title on every listing).
    private func botChatMode(_ target: AppModel.BotChatTarget) -> ChatController.Mode {
        if let storedID = target.storedID {
            return .resume(
                SessionSummary(
                    json: .object([
                        "session_id": .string(storedID),
                        "profile": .string(target.profile),
                    ]))!)
        }
        return .create(cwd: nil, title: "Bot Chat")
    }
}
