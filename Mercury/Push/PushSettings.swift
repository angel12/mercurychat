import Foundation
import MercuryKit

/// Per-server Mercury Push choices. Not secret: pairing credentials live in
/// MercuryKit's Keychain store, not here.
struct ServerPushSettings: Codable, Equatable, Sendable {
    var enabled = false
    /// Profiles the user switched off (every other profile the server lists is on).
    var disabledProfiles: Set<String> = []
    var preferences = PushPreferences()
    /// Which sessions notify this device: every session, or only ones it started or messaged.
    var sessionScope = PushSessionScope.all
}

// In an extension so the memberwise initializer survives.
extension ServerPushSettings {
    // Settings saved before `sessionScope` existed must still decode (a failed decode loads as
    // empty, switching push off everywhere), so each field falls back to its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            disabledProfiles: try container.decodeIfPresent(Set<String>.self, forKey: .disabledProfiles) ?? [],
            preferences: try container.decodeIfPresent(PushPreferences.self, forKey: .preferences)
                ?? PushPreferences(),
            sessionScope: try container.decodeIfPresent(PushSessionScope.self, forKey: .sessionScope) ?? .all)
    }
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
