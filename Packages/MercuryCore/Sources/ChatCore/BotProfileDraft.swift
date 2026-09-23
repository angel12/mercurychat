import MercuryKit

/// The advanced bot editor's working copy. `changes()` carries only the
/// sections that differ from the loaded profile, using the rules hermes
/// desktop saves with (`applyAdvancedConfig`, hermes-bots `profile-config.tsx`).
public struct BotProfileDraft: Equatable, Sendable {
    public let original: ProfileDescription
    public var soul: String
    /// Setting nil is ignored: unpinning isn't offered.
    public var model: ProfileDescription.ModelPin?
    public var skills: [ProfileDescription.Capability]
    public var toolsets: [ProfileDescription.Toolset]
    public var mcpServers: [ProfileDescription.MCPServer]

    public init(_ original: ProfileDescription) {
        self.original = original
        soul = original.soul
        model = original.model
        skills = original.skills
        toolsets = original.toolsets
        mcpServers = original.mcpServers
    }

    public var hasChanges: Bool { changes() != ProfileChanges() }

    public func changes() -> ProfileChanges {
        var changes = ProfileChanges()
        if soul != original.soul { changes.soul = soul }
        if let model, model != original.model { changes.model = model }
        if skills != original.skills {
            changes.disabledSkills = skills.filter { !$0.enabled }.map(\.name)
        }
        if toolsets != original.toolsets {
            let enabled = toolsets.filter(\.enabled)
            changes.enabledToolsets = enabled.count == toolsets.count || enabled.isEmpty ? [] : enabled.map(\.name)
        }
        if mcpServers != original.mcpServers {
            changes.enabledMCPServers = mcpServers.filter(\.enabled).map(\.name)
        }
        return changes
    }
}
