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

    @Test func sessionScopeDefaultsToAllAndRoundTrips() {
        #expect(ServerPushSettings().sessionScope == .all)
        let defaults = UserDefaults(suiteName: "push-settings-\(UUID().uuidString)")!
        let store = PushSettingsStore(defaults: defaults)
        var server = ServerPushSettings()
        server.sessionScope = .owned
        store.save(["https://hermes.example:443": server])
        #expect(PushSettingsStore(defaults: defaults).load()["https://hermes.example:443"]?.sessionScope == .owned)
    }

    /// Builds before 0.6.0 saved no `sessionScope`: their settings must still load (a failed
    /// decode loads as empty, which would switch push off for every server on upgrade).
    @Test func settingsSavedBeforeSessionScopeStillLoad() {
        let defaults = UserDefaults(suiteName: "push-settings-\(UUID().uuidString)")!
        let old = #"{"https://hermes.example:443":{"enabled":true,"disabledProfiles":["noisy"],"preferences":{"approval":true,"responseReady":true,"turnFailed":true,"taskDone":true,"cron":false}}}"#
        defaults.set(Data(old.utf8), forKey: PushSettingsStore.defaultsKey)
        let loaded = PushSettingsStore(defaults: defaults).load()["https://hermes.example:443"]
        #expect(loaded?.enabled == true)
        #expect(loaded?.disabledProfiles == ["noisy"])
        #expect(loaded?.preferences == PushPreferences(cron: false))
        #expect(loaded?.sessionScope == .all)
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
