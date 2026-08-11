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

    private var mainScene: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.autoConnectOnLaunch() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Skip any reconnect backoff the moment the app is visible again.
            if phase == .active { model.appBecameActive() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session") {
                    model.requestNewSession()
                }
                .keyboardShortcut("n")
                .disabled(!model.isConnected)
            }
        }
    }
}
