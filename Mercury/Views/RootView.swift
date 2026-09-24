import MercuryKit
import SwiftUI

/// One window's root. Each window owns its navigation (#112): the route
/// lives here, per scene, not on the app-wide model — so opening a session
/// in one window leaves every other window's conversation where it was.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var navigation = WindowNavigation()

    var body: some View {
        Group {
            if model.isConnected {
                ConnectedView()
            } else {
                ConnectView()
            }
        }
        .environment(navigation)
        // The menu bar's New Session acts on the focused window's
        // navigation; nil (no key window) disables it.
        .focusedSceneValue(\.windowNavigation, navigation)
        .onAppear { model.register(navigation) }
    }
}

extension FocusedValues {
    /// The focused window's navigation, for scene-targeted menu commands.
    var windowNavigation: WindowNavigation? {
        get { self[WindowNavigationKey.self] }
        set { self[WindowNavigationKey.self] = newValue }
    }

    private struct WindowNavigationKey: FocusedValueKey {
        typealias Value = WindowNavigation
    }
}

/// The connected shell: split view on regular widths (iPad/Mac/Vision),
/// drill-in stack on iPhone.
struct ConnectedView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowNavigation.self) private var navigation
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
            switch navigation.route {
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
