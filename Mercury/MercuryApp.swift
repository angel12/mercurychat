import SwiftUI

@main
struct MercuryApp: App {
    @State private var model: AppModel
    #if os(macOS)
        /// The global mute shortcut (Settings › Voice).
        @State private var hotKeys: VoiceHotKeyController
    #endif
    #if os(iOS) || os(visionOS)
        @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // Shortcuts and Siri reach the voice conversation through this.
        VoiceIntentBridge.shared = model
        #if os(macOS)
            let hotKeys = VoiceHotKeyController(
                store: VoiceHotKeyStore(defaults: .standard), registrar: CarbonHotKeyRegistrar())
            hotKeys.onPress = { [weak model] in
                Task { _ = try? await model?.intentSetMute(nil) }
            }
            model.onVoiceActiveChanged = { [weak hotKeys] active in hotKeys?.isArmed = active }
            _hotKeys = State(initialValue: hotKeys)
        #endif
    }

    var body: some Scene {
        mainScene

        #if os(macOS)
            Settings {
                SettingsView()
                    .environment(model)
                    .environment(hotKeys)
            }
        #endif
    }

    /// The chat window group's id, for New Window (`openWindow`).
    static let mainWindowID = "main"

    private var mainScene: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            RootView()
                .environment(model)
                .task {
                    #if os(iOS) || os(visionOS)
                        appDelegate.model = model
                    #endif
                    #if os(iOS)
                        await model.push.applicationDidLaunch()
                    #endif
                    await model.autoConnectOnLaunch()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Skip any reconnect backoff the moment the app is visible again.
            if phase == .active { model.appBecameActive() }
            if phase == .background { model.appEnteredBackground() }
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
