import SwiftUI

@main
struct MercuryApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        mainScene

        #if os(macOS)
            Settings {
                SettingsView()
                    .environment(model)
            }
        #endif
    }

    /// The chat window group's id, for New Window (`openWindow`).
    static let mainWindowID = "main"

    private var mainScene: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            RootView()
                .environment(model)
                .task { await model.autoConnectOnLaunch() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Skip any reconnect backoff the moment the app is visible again.
            if phase == .active { model.appBecameActive() }
        }
        .commands {
            MercuryCommands(model: model)
        }
    }
}

/// File-menu commands (#112). The WindowGroup's default New Window also
/// claims ⌘N, so the group is replaced: New Session keeps ⌘N and acts on the
/// focused window only (the hermes desktop mapping), New Window moves to ⇧⌘N.
struct MercuryCommands: Commands {
    let model: AppModel
    @FocusedValue(\.windowNavigation) private var navigation
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") {
                if let navigation { model.requestNewSession(in: navigation) }
            }
            .keyboardShortcut("n")
            .disabled(navigation == nil || !model.isConnected)

            if supportsMultipleWindows {
                Button("New Window") {
                    openWindow(id: MercuryApp.mainWindowID)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}
