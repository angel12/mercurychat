import MercuryKit
import Testing

@testable import ChatCore

/// The advanced editor saves only what changed, with the desktop's rules
/// (`applyAdvancedConfig` in hermes-bots `profile-config.tsx`).
@Suite("Bot profile draft")
struct BotProfileDraftTests {
    private func original(toolsetsEnabled: [Bool] = [true, false]) throws -> ProfileDescription {
        var profile = try #require(ProfileDescription(json: ["name": "scout", "model": [:]]))
        profile.soul = "# Scout"
        profile.skills = [.init(name: "arxiv", enabled: true), .init(name: "pdf", enabled: false)]
        profile.toolsets = zip(["web", "terminal"], toolsetsEnabled).map {
            .init(name: $0, label: "", description: "", toolCount: 1, enabled: $1)
        }
        profile.mcpServers = [.init(name: "linear", enabled: false, transport: "http")]
        return profile
    }

    @Test func anUntouchedDraftSendsNothing() throws {
        let draft = BotProfileDraft(try original())
        #expect(!draft.hasChanges)
        #expect(draft.changes() == ProfileChanges())
    }

    @Test func onlyTheChangedSectionIsSent() throws {
        var draft = BotProfileDraft(try original())
        draft.soul = "# Scout\nBe brief."
        #expect(draft.changes() == ProfileChanges(soul: "# Scout\nBe brief."))
    }

    /// Toggling back to the original is no change.
    @Test func aToggleUndoneIsNoChange() throws {
        var draft = BotProfileDraft(try original())
        draft.skills[1].enabled = true
        draft.skills[1].enabled = false
        #expect(!draft.hasChanges)
    }

    @Test func skillsSendTheCompleteDisabledList() throws {
        var draft = BotProfileDraft(try original())
        draft.skills[0].enabled = false
        #expect(draft.changes().disabledSkills == ["arxiv", "pdf"])
    }

    @Test func mcpSendsTheCompleteEnabledList() throws {
        var draft = BotProfileDraft(try original())
        draft.mcpServers[0].enabled = true
        #expect(draft.changes().enabledMCPServers == ["linear"])
    }

    /// All on, or all off, clears the pin; a partial set pins it.
    @Test(arguments: [
        ([true, false], [true, true], [String]()),
        ([true, false], [false, false], [String]()),
        ([true, true], [false, true], ["terminal"]),
    ])
    func theToolsetPinRule(from: [Bool], to: [Bool], sent: [String]) throws {
        var draft = BotProfileDraft(try original(toolsetsEnabled: from))
        for index in to.indices { draft.toolsets[index].enabled = to[index] }
        #expect(draft.changes().enabledToolsets == sent)
    }

    @Test func aNewModelPinIsSent() throws {
        var draft = BotProfileDraft(try original())
        draft.model = .init(provider: "openai-codex", model: "gpt-5.6-sol")
        #expect(draft.changes() == ProfileChanges(model: .init(provider: "openai-codex", model: "gpt-5.6-sol")))
    }

    /// Unpinning isn't supported (the desktop shells out for it), so a
    /// cleared pin sends nothing.
    @Test func clearingThePinSendsNothing() throws {
        var profile = try original()
        profile.model = .init(provider: "p", model: "m")
        var draft = BotProfileDraft(profile)
        draft.model = nil
        #expect(draft.changes().model == nil)
    }

    /// `profiles.describe` sometimes reports every toolset as off even
    /// though the bot really has toolsets enabled (seen on hermes 0.21.4;
    /// cause unknown). Editing from that state would replace the real
    /// toolsets with just whatever the user toggled, so the section is
    /// read-only until the server can report the real list.
    @Test(arguments: [true, false])
    func allToolsetsOffIsNotEditable(pinned: Bool) throws {
        var profile = try original(toolsetsEnabled: [false, false])
        profile.toolsetsPinned = pinned
        var draft = BotProfileDraft(profile)
        #expect(!draft.toolsetsEditable)

        draft.toolsets[0].enabled = true
        #expect(draft.changes().enabledToolsets == nil)
        #expect(!draft.hasChanges)
    }

    @Test func anExplicitPinIsEditable() throws {
        var profile = try original(toolsetsEnabled: [true, false])
        profile.toolsetsPinned = true
        let draft = BotProfileDraft(profile)
        #expect(draft.toolsetsEditable)
    }

    @Test func anUnpinnedProfileIsEditable() throws {
        var profile = try original(toolsetsEnabled: [true, false])
        profile.toolsetsPinned = false
        let draft = BotProfileDraft(profile)
        #expect(draft.toolsetsEditable)
    }

    @Test func anEmptyToolsetListIsEditable() throws {
        var profile = try original(toolsetsEnabled: [])
        profile.toolsetsPinned = true
        let draft = BotProfileDraft(profile)
        #expect(draft.toolsetsEditable)
    }
}
