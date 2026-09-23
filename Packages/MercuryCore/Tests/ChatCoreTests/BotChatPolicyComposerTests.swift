import MercuryKit
import Testing

@testable import ChatCore

/// The canonical Bot Chat's composer rule. It lives in ChatCore, not
/// MercuryKit: turning `/new`, `/reset` and `/compact` into compression is a
/// UI decision, so the shared kit leaves it to the app. Moved from Chat's
/// embedded `MercuryKitTests/BotRosterTests.swift` unchanged.
@Suite("BotChatPolicy composer")
struct BotChatPolicyComposerTests {
    @Test func compactCommandsAreIntercepted() {
        #expect(BotChatPolicy.isCompactCommand("/new"))
        #expect(BotChatPolicy.isCompactCommand("/reset"))
        #expect(BotChatPolicy.isCompactCommand("/compact"))
        #expect(BotChatPolicy.isCompactCommand("  /new fresh start  "))
        #expect(BotChatPolicy.isCompactCommand("/NEW"))
    }

    @Test func everythingElsePassesThrough() {
        #expect(!BotChatPolicy.isCompactCommand("/newer things"))
        #expect(!BotChatPolicy.isCompactCommand("tell me about /new"))
        #expect(!BotChatPolicy.isCompactCommand("hello"))
        #expect(!BotChatPolicy.isCompactCommand(""))
    }
}
