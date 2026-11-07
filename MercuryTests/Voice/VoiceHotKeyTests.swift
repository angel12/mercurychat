import AppKit
import Foundation
import Testing

@MainActor
final class FakeHotKeyRegistrar: HotKeyRegistering {
    var refused: Set<VoiceHotKey> = []
    private(set) var registered: VoiceHotKey?
    private(set) var registrations: [VoiceHotKey] = []
    private var onPress: (@MainActor () -> Void)?

    func register(_ hotKey: VoiceHotKey, onPress: @escaping @MainActor () -> Void) -> Bool {
        registrations.append(hotKey)
        guard !refused.contains(hotKey) else { return false }
        registered = hotKey
        self.onPress = onPress
        return true
    }

    func unregister() {
        registered = nil
        onPress = nil
    }

    func press() { onPress?() }
}

@MainActor
@Suite("Voice mute hotkey")
struct VoiceHotKeyTests {
    private let f5 = VoiceHotKey(keyCode: 96, modifiers: [.control, .shift])

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "voice-hotkey-tests-\(UUID().uuidString)")!
    }

    private func makeController(
        _ defaults: UserDefaults, _ registrar: FakeHotKeyRegistrar
    ) -> VoiceHotKeyController {
        VoiceHotKeyController(store: VoiceHotKeyStore(defaults: defaults), registrar: registrar)
    }

    // MARK: Model

    @Test func defaultIsOptionCommandM() {
        #expect(VoiceHotKey.defaultMute.displayString == "⌥⌘M")
        #expect(VoiceHotKey.defaultMute.carbonModifiers == 0x900)  // optionKey | cmdKey
        #expect(VoiceHotKey.defaultMute.isValid)
    }

    @Test func displayOrdersModifiersLikeMenus() {
        #expect(f5.displayString == "⌃⇧F5")
        #expect(VoiceHotKey(keyCode: 49, modifiers: [.command, .shift, .option, .control]).displayString == "⌃⌥⇧⌘Space")
        #expect(VoiceHotKey(keyCode: 999, modifiers: [.command]).displayString == "⌘Key 999")
        #expect(f5.carbonModifiers == 0x1200)  // controlKey | shiftKey
    }

    @Test func needsCommandOrControl() {
        #expect(!VoiceHotKey(keyCode: 46, modifiers: [.option]).isValid)
        #expect(!VoiceHotKey(keyCode: 46, modifiers: [.option, .shift]).isValid)
        #expect(!VoiceHotKey(keyCode: 46, modifiers: []).isValid)
        #expect(VoiceHotKey(keyCode: 46, modifiers: [.control]).isValid)
    }

    @Test func buildsFromEventFlags() {
        let key = VoiceHotKey(keyCode: 46, flags: [.command, .option, .capsLock, .function])
        #expect(key == .defaultMute)
    }

    // MARK: Store

    @Test func storeDefaultsClearsAndRoundTrips() {
        let defaults = freshDefaults()
        let store = VoiceHotKeyStore(defaults: defaults)
        #expect(store.load() == .defaultMute)
        store.save(f5)
        #expect(store.load() == f5)
        store.save(nil)
        #expect(store.load() == nil)
        defaults.set(Data("junk".utf8), forKey: VoiceHotKeyStore.key)
        #expect(store.load() == .defaultMute)
    }

    // MARK: Controller

    @Test func registersOnlyWhileArmed() {
        let registrar = FakeHotKeyRegistrar()
        let controller = makeController(freshDefaults(), registrar)
        #expect(registrar.registered == nil)
        controller.isArmed = true
        #expect(registrar.registered == .defaultMute)
        controller.isArmed = false
        #expect(registrar.registered == nil)
    }

    @Test func pressCallsOnPress() {
        let registrar = FakeHotKeyRegistrar()
        let controller = makeController(freshDefaults(), registrar)
        var presses = 0
        controller.onPress = { presses += 1 }
        controller.isArmed = true
        registrar.press()
        #expect(presses == 1)
    }

    @Test func setReRegistersAndPersists() {
        let defaults = freshDefaults()
        let registrar = FakeHotKeyRegistrar()
        let controller = makeController(defaults, registrar)
        controller.isArmed = true
        controller.set(f5)
        #expect(registrar.registered == f5)
        #expect(makeController(defaults, FakeHotKeyRegistrar()).hotKey == f5)
        controller.resetToDefault()
        #expect(registrar.registered == .defaultMute)
    }

    @Test func clearUnregisters() {
        let defaults = freshDefaults()
        let registrar = FakeHotKeyRegistrar()
        let controller = makeController(defaults, registrar)
        controller.isArmed = true
        controller.set(nil)
        #expect(registrar.registered == nil)
        #expect(controller.hotKey == nil)
        #expect(makeController(defaults, FakeHotKeyRegistrar()).hotKey == nil)
    }

    @Test func invalidShortcutIsIgnored() {
        let registrar = FakeHotKeyRegistrar()
        let controller = makeController(freshDefaults(), registrar)
        controller.set(VoiceHotKey(keyCode: 46, modifiers: [.option]))
        #expect(controller.hotKey == .defaultMute)
    }

    @Test func refusedShortcutIsReported() {
        let registrar = FakeHotKeyRegistrar()
        registrar.refused = [f5]
        let controller = makeController(freshDefaults(), registrar)
        // Unarmed: a probe registration still tells the settings row.
        controller.set(f5)
        #expect(controller.registrationFailed)
        #expect(registrar.registered == nil)
        controller.resetToDefault()
        #expect(!controller.registrationFailed)
        #expect(registrar.registered == nil)  // the probe let go again
        controller.set(f5)
        controller.isArmed = true
        #expect(controller.registrationFailed)
    }

    @Test func suspendReleasesUntilResumed() {
        let registrar = FakeHotKeyRegistrar()
        let controller = makeController(freshDefaults(), registrar)
        controller.isArmed = true
        controller.suspend()
        #expect(registrar.registered == nil)
        controller.set(f5)
        #expect(registrar.registered == nil)
        controller.resume()
        #expect(registrar.registered == f5)
    }
}
