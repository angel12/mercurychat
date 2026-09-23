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

    /// False when `profiles.describe` reported every toolset as disabled
    /// while the list itself is non-empty. That combination can't reflect
    /// reality: an unpinned profile always gets the (non-empty) platform
    /// defaults, and upstream clears an explicit pin whenever the enabled
    /// list is empty. Yet hermes 0.21.4 (and `main` at `36d2229e38`) reports
    /// exactly that whenever a named profile exists: the multiplexing
    /// gateway refuses the unscoped `XAI_API_KEY` read inside
    /// `_get_platform_tools`, and `_describe_toolsets` swallows the error
    /// as "nothing enabled". Saving toolsets from that state would replace
    /// the bot's real toolsets with whatever was toggled, so the section
    /// stays read-only. Remove once `profiles.describe` scopes that read.
    public var toolsetsEditable: Bool {
        !(!original.toolsets.isEmpty && original.toolsets.allSatisfy { !$0.enabled })
    }

    public func changes() -> ProfileChanges {
        var changes = ProfileChanges()
        if soul != original.soul { changes.soul = soul }
        if let model, model != original.model { changes.model = model }
        if skills != original.skills {
            changes.disabledSkills = skills.filter { !$0.enabled }.map(\.name)
        }
        if toolsetsEditable && toolsets != original.toolsets {
            let enabled = toolsets.filter(\.enabled)
            changes.enabledToolsets = enabled.count == toolsets.count || enabled.isEmpty ? [] : enabled.map(\.name)
        }
        if mcpServers != original.mcpServers {
            changes.enabledMCPServers = mcpServers.filter(\.enabled).map(\.name)
        }
        return changes
    }
}
