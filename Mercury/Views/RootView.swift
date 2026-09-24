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
            case .newSession(let cwd, let request):
                // Keyed by the request, not the cwd (#97): every New Session
                // action gets a fresh ChatView and create task, while view
                // refreshes of the same request never create twice.
                ChatView(mode: .create(cwd: cwd, title: nil), sessionKey: "new-\(request)")
                    .id("new-session-\(request)")
            case .botChat(let target):
                // The canonical chat is resolved inside begin(.bot) by the
                // exact-title registry lookup — never from the roster row,
                // which can be stale. The row's sighting only rides along so
                // an empty lookup that contradicts it fails closed.
                ChatView(
                    mode: .bot(
                        profile: target.profile,
                        expectCanonical: target.storedID != nil),
                    sessionKey: "bot-\(target.profile)",
                    botContext: .init(
                        profile: target.profile, displayTitle: target.displayTitle,
                        kickoff: target.kickoff)
                )
                .id("bot-\(target.profile)")
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

}
