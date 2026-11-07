import AppIntents
import Foundation

/// A stored session a Shortcut can resume by voice. The id carries the
/// profile and stored id, so a saved Shortcut resolves without a connection.
struct VoiceSessionEntity: AppEntity, Equatable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Voice Session"
    static let defaultQuery = VoiceSessionQuery()

    let id: String
    let storedID: String
    /// nil = the server's default profile.
    let profile: String?
    let title: String

    init(storedID: String, profile: String?, title: String) {
        self.id = Self.makeID(storedID: storedID, profile: profile)
        self.storedID = storedID
        self.profile = profile
        self.title = title
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)", subtitle: profile.map { LocalizedStringResource(stringLiteral: $0) })
    }

    /// `"<profile>|<storedID>"`; an empty profile is the default one.
    static func makeID(storedID: String, profile: String?) -> String {
        "\(profile ?? "")|\(storedID)"
    }

    /// Splits at the first `|`: profile names never contain one, stored ids might.
    static func parse(id: String) -> (storedID: String, profile: String?)? {
        guard let bar = id.firstIndex(of: "|") else { return nil }
        let profile = String(id[..<bar])
        let storedID = String(id[id.index(after: bar)...])
        guard !storedID.isEmpty else { return nil }
        return (storedID, profile.isEmpty ? nil : profile)
    }
}

struct VoiceSessionQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [VoiceSessionEntity] {
        let choices = await VoiceIntentBridge.sessionChoices()
        return Self.resolve(identifiers, choices: choices)
    }

    func suggestedEntities() async throws -> [VoiceSessionEntity] {
        await VoiceIntentBridge.sessionChoices()
    }

    /// Known sessions keep their titles; others resolve from the id alone.
    static func resolve(_ identifiers: [String], choices: [VoiceSessionEntity])
        -> [VoiceSessionEntity]
    {
        identifiers.compactMap { id in
            if let known = choices.first(where: { $0.id == id }) { return known }
            guard let parsed = VoiceSessionEntity.parse(id: id) else { return nil }
            return VoiceSessionEntity(
                storedID: parsed.storedID, profile: parsed.profile, title: "Session")
        }
    }
}

/// A profile a new voice conversation can start in.
struct VoiceProfileEntity: AppEntity, Equatable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Profile"
    static let defaultQuery = VoiceProfileQuery()

    /// The profile name.
    let id: String
    let displayName: String

    init(name: String, displayName: String) {
        self.id = name
        self.displayName = displayName
    }

    var name: String { id }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
}

struct VoiceProfileQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [VoiceProfileEntity] {
        let choices = await VoiceIntentBridge.profileChoices()
        return Self.resolve(identifiers, choices: choices)
    }

    func suggestedEntities() async throws -> [VoiceProfileEntity] {
        await VoiceIntentBridge.profileChoices()
    }

    static func resolve(_ identifiers: [String], choices: [VoiceProfileEntity])
        -> [VoiceProfileEntity]
    {
        identifiers.map { name in
            choices.first { $0.id == name } ?? VoiceProfileEntity(name: name, displayName: name)
        }
    }
}

/// What "Mute voice" does. Live Activity buttons pass `.mute`/`.unmute`.
enum VoiceMuteAction: String, AppEnum, Sendable {
    case toggle
    case mute
    case unmute

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mute Action"
    static let caseDisplayRepresentations: [VoiceMuteAction: DisplayRepresentation] = [
        .toggle: "Toggle mute",
        .mute: "Mute",
        .unmute: "Unmute",
    ]

    /// The muted state asked for; nil toggles.
    var target: Bool? {
        switch self {
        case .toggle: nil
        case .mute: true
        case .unmute: false
        }
    }
}
