import Foundation
import MercuryKit

/// Per-server Mercury Push choices. Not secret: pairing credentials live in
/// MercuryKit's Keychain store, not here.
struct ServerPushSettings: Codable, Equatable, Sendable {
    var enabled = false
    /// Profiles the user switched off (every other profile the server lists is on).
    var disabledProfiles: Set<String> = []
    var preferences = PushPreferences()
}

/// `UserDefaults["pushSettings"]`: JSON `[ServerEndpoint.key: ServerPushSettings]`.
@MainActor
final class PushSettingsStore {
    static let defaultsKey = "pushSettings"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> [String: ServerPushSettings] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([String: ServerPushSettings].self, from: data)
        else { return [:] }
        return decoded
    }

    func save(_ all: [String: ServerPushSettings]) {
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
