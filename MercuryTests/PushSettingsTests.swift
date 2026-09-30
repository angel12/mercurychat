import Foundation
import MercuryKit
import Testing

@Suite("Push settings")
@MainActor
struct PushSettingsTests {
    @Test func roundTripsPerServerSettings() {
        let defaults = UserDefaults(suiteName: "push-settings-\(UUID().uuidString)")!
        let store = PushSettingsStore(defaults: defaults)
        #expect(store.load().isEmpty)
        var server = ServerPushSettings()
        server.enabled = true
        server.disabledProfiles = ["noisy"]
        server.preferences = PushPreferences(cron: false)
        store.save(["https://hermes.example:443": server])
        #expect(PushSettingsStore(defaults: defaults).load() == ["https://hermes.example:443": server])
        #expect(defaults.data(forKey: PushSettingsStore.defaultsKey) != nil)
    }

    @Test func defaultsAreOffWithAllKinds() {
        let settings = ServerPushSettings()
        #expect(settings.enabled == false)
        #expect(settings.disabledProfiles.isEmpty)
        #expect(settings.preferences == PushPreferences())
    }

    @Test func corruptDataLoadsEmpty() {
        let defaults = UserDefaults(suiteName: "push-settings-\(UUID().uuidString)")!
        defaults.set(Data("nope".utf8), forKey: PushSettingsStore.defaultsKey)
        #expect(PushSettingsStore(defaults: defaults).load().isEmpty)
    }

    @Test func factoryIsInertOffIOS() async {
        let system = PushSystemFactory.make()
        #expect(await system.authorizationStatus() == .denied)  // macOS test host: NoPushSystem
        #expect(await system.requestAuthorization() == false)
    }
}
