import Foundation
import Testing

@testable import ChatCore

/// The New Bot quick path (#27 Phase 3) derives what it sends from what the
/// user typed, the way hermes desktop's hermes-bots plugin does. The slug
/// cases are the desktop's own (`labels.profile-name.test.ts` at hermes-agent
/// `16fe260aab`), so both clients name a bot identically.
@Suite("Bot creation")
struct BotCreationTests {
    // MARK: Profile id

    @Test(arguments: [
        ("Inbox Triage", "inbox-triage"),
        ("小助手", "u5c0f-u52a9-u624b"),
        ("test机器人", "test-u673a-u5668-u4eba"),
        // Already a slug: unchanged.
        ("u5c0f-u52a9-u624b", "u5c0f-u52a9-u624b"),
        ("Café Résumé", "cafe-resume"),
        // One token per NFC code point: Hangul doesn't decompose to jamo.
        ("한글", "ud55c-uae00"),
        ("🤖", ""),
        ("  Research   Bot!  ", "research-bot"),
        ("snake_case-ok", "snake_case-ok"),
    ])
    func profileSlug(name: String, slug: String) {
        #expect(BotCreation.profileSlug(for: name) == slug)
    }

    @Test func distinctKanaStayDistinct() {
        #expect(BotCreation.profileSlug(for: "ガ") != BotCreation.profileSlug(for: "カ"))
    }

    /// Past the 64-character cap the id is cut at a token boundary, so no
    /// `u<hex>` token turns into a different code point.
    @Test func aLongNameIsCutAtATokenBoundary() {
        let slug = BotCreation.profileSlug(for: String(repeating: "小助手", count: 7))
        #expect(slug == "u5c0f-u52a9-u624b-u5c0f-u52a9-u624b-u5c0f-u52a9-u624b-u5c0f")
        #expect(BotCreation.isValidProfileID(slug))
    }

    /// `hermes_constants.PROFILE_ID_RE`: `^[a-z0-9][a-z0-9_-]{0,63}$`.
    @Test(arguments: [
        ("scout", true), ("a", true), ("scout-2_b", true),
        (String(repeating: "a", count: 64), true), (String(repeating: "a", count: 65), false),
        ("", false), ("-scout", false), ("_scout", false), ("Scout", false), ("sc out", false),
    ])
    func profileIDValidity(id: String, valid: Bool) {
        #expect(BotCreation.isValidProfileID(id) == valid)
    }

    // MARK: Identity

    /// A non-ASCII name can't be the profile id, so it survives as the title
    /// when the Title field was left empty.
    @Test(arguments: [
        ("小助手", "", "u5c0f-u52a9-u624b", "小助手"),
        ("小助手", "Helper", "u5c0f-u52a9-u624b", "Helper"),
        ("Test", "", "test", ""),
        ("🤖", "", "", "🤖"),
        ("Café", "", "cafe", "Café"),
        ("Scout", "  Researcher  ", "scout", "Researcher"),
    ])
    func identity(name: String, title: String, slug: String, resolvedTitle: String) {
        let identity = BotCreation.identity(name: name, title: title)
        #expect(identity.slug == slug)
        #expect(identity.title == resolvedTitle)
    }

    @Test(arguments: [
        ("scout", "", "Scout"),
        ("inbox-triage", "", "Inbox Triage"),
        ("scout", "Radar", "Radar"),
        ("snake_case", "", "Snake Case"),
    ])
    func displayName(slug: String, title: String, expected: String) {
        #expect(BotCreation.displayName(slug: slug, title: title) == expected)
    }

    // MARK: What's sent

    /// The desktop's `composeSoul` identity text. The messaging protocol is
    /// left out: every backend Chat supports injects it itself.
    @Test func soulWithRoleAndMission() {
        #expect(
            BotCreation.soul(slug: "scout", title: "Researcher", description: "Finds things out")
                == """
                # Researcher

                **Role:** Researcher
                **Mission:** Finds things out

                You are Researcher, a persistent named agent (profile `scout`) on this machine.
                You keep your own memory, skills, and conversation history across sessions.
                """)
    }

    @Test func soulWithNameOnly() {
        #expect(
            BotCreation.soul(slug: "inbox-triage", title: "", description: "")
                == """
                # Inbox Triage


                You are Inbox Triage, a persistent named agent (profile `inbox-triage`) on this machine.
                You keep your own memory, skills, and conversation history across sessions.
                """)
    }

    @Test(arguments: [
        ("Researcher", "Finds things out", "Researcher — Finds things out" as String?),
        ("Researcher", "", "Researcher"),
        ("", "Finds things out", "Finds things out"),
        ("", "", nil),
    ])
    func profileDescription(title: String, description: String, expected: String?) {
        #expect(BotCreation.profileDescription(title: title, description: description) == expected)
    }

    @Test func kickoffMatchesTheDesktop() {
        #expect(BotCreation.kickoff == "Hey, tell me about yourself!")
    }
}
