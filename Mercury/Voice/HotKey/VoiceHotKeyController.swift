import Foundation
import Observation

/// The system's global hot keys (Carbon on macOS, a fake in tests).
@MainActor
protocol HotKeyRegistering: AnyObject {
    /// Replaces any earlier registration. False when the system refused it.
    func register(_ hotKey: VoiceHotKey, onPress: @escaping @MainActor () -> Void) -> Bool
    func unregister()
}

/// The macOS mute shortcut (sub-project 5). Registered only while armed (a
/// voice conversation is running) and not suspended (the recorder is
/// listening), so the combination stays free for other apps otherwise.
@MainActor @Observable
final class VoiceHotKeyController {
    /// nil = cleared.
    private(set) var hotKey: VoiceHotKey?
    /// The system refused the shortcut (another app may hold it).
    private(set) var registrationFailed = false

    var isArmed = false {
        didSet { if isArmed != oldValue { apply() } }
    }

    @ObservationIgnored var onPress: (@MainActor () -> Void)?
    @ObservationIgnored private let store: VoiceHotKeyStore
    @ObservationIgnored private let registrar: any HotKeyRegistering
    @ObservationIgnored private var suspended = false

    init(store: VoiceHotKeyStore, registrar: any HotKeyRegistering) {
        self.store = store
        self.registrar = registrar
        self.hotKey = store.load()
    }

    /// A new shortcut, or nil to clear it. Invalid shortcuts are ignored.
    func set(_ newValue: VoiceHotKey?) {
        if let newValue, !newValue.isValid { return }
        hotKey = newValue
        store.save(newValue)
        registrationFailed = false
        if isArmed, !suspended {
            apply()
        } else if let newValue {
            // Not live now: try it once so a refused combination shows up
            // in Settings rather than silently during the next call.
            registrationFailed = !registrar.register(newValue, onPress: {})
            registrar.unregister()
        }
    }

    func resetToDefault() { set(.defaultMute) }

    /// The recorder is listening: release the key so it can be typed.
    func suspend() {
        suspended = true
        apply()
    }

    func resume() {
        suspended = false
        apply()
    }

    private func apply() {
        registrar.unregister()
        guard isArmed, !suspended, let hotKey else { return }
        registrationFailed = !registrar.register(hotKey) { [weak self] in self?.onPress?() }
    }
}
