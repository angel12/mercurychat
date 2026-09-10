import Foundation
import Testing

@testable import MercuryKit

private func json(_ text: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Suite("BotSummary parsing")
struct BotSummaryTests {
    /// A realistic `profiles.list` row from a v0.21.x gateway with Bot Mode
    /// metadata, a canonical chat, and a live worker.
    static let fullRow = """
        {
          "name": "researcher", "path": "/home/u/.hermes/profiles/researcher",
          "is_default": false, "model": "gpt-5.6-sol", "provider": "openai-codex",
          "description": "Deep-dive research agent", "display_name": "Researcher",
          "skill_count": 12, "has_avatar": true,
          "ui_meta": {
            "hermes-bots": {
              "title": "Radar", "description": "Finds things out",
              "shape": "hexagon", "color": "#8b5cf6",
              "hidden": false, "pinned": true, "created": 1756000000000
            }
          },
          "ui_meta_revisions": {"hermes-bots": 7},
          "last_session": {
            "id": "20260907_101010_aa11", "title": "Group: ops",
            "preview": "On it.", "started_at": 1757000000,
            "last_active": 1757260000, "message_count": 41
          },
          "canonical_session": {
            "id": "20260830_090000_bb22", "resolved_id": "20260906_120000_cc33",
            "root_title": "Bot Chat", "title": "Bot Chat",
            "preview": "Here's the summary you asked for.",
            "started_at": 1756500000, "last_active": 1757250000, "message_count": 230
          },
          "worker_session": {
            "id": "20260908_070000_dd44", "source": "kanban",
            "title": "worker", "last_active": 1757310000
          }
        }
        """

    @Test func parsesFullRow() throws {
        let bot = try #require(BotSummary(json: json(Self.fullRow)))
        #expect(bot.name == "researcher")
        #expect(bot.title == "Radar")  // ui_meta title beats display_name
        #expect(bot.shape == "hexagon")
        #expect(bot.colorHex == "#8b5cf6")
        #expect(bot.pinned)
        #expect(!bot.hidden)
        #expect(bot.hasAvatar)
        #expect(bot.skillCount == 12)

        let canonical = try #require(bot.canonicalSession)
        #expect(canonical.storedID == "20260830_090000_bb22")
        #expect(canonical.resolvedID == "20260906_120000_cc33")
        #expect(canonical.messageCount == 230)

        // The canonical chat's preview is the row's click target, so it
        // wins over the newer last_session preview.
        #expect(bot.preview == "Here's the summary you asked for.")
        // Activity = max(canonical, last, worker) — the worker is newest.
        #expect(bot.lastActivity == Date(timeIntervalSince1970: 1_757_310_000))
    }

    @Test func parsesBareProfileWithoutBotMeta() throws {
        // A profile Bot Mode never touched: no ui_meta, no sessions walked
        // (include_sessions=false shape).
        let bot = try #require(
            BotSummary(
                json: json(
                    """
                    {"name": "default", "path": "/h", "is_default": true,
                     "model": null, "provider": null, "description": "",
                     "display_name": "", "skill_count": 0}
                    """)))
        #expect(bot.isDefault)
        #expect(bot.title == "default")  // empty display_name falls through
        #expect(!bot.hidden && !bot.pinned && !bot.hasAvatar)
        #expect(bot.canonicalSession == nil)
        #expect(bot.preview == nil)
        #expect(bot.lastActivity == nil)
    }

    @Test func rowWithoutNameIsRejected() {
        #expect(BotSummary(json: json(#"{"is_default": false}"#)) == nil)
    }
}

@Suite("ProfileAsset parsing")
struct ProfileAssetTests {
    @Test func decodesDataURL() throws {
        let payload = Data("PNGBYTES".utf8).base64EncodedString()
        let asset = try #require(
            ProfileAsset(
                json: json(
                    """
                    {"found": true, "mime": "image/png", "size": 8,
                     "data": "data:image/png;base64,\(payload)"}
                    """)))
        #expect(asset.mime == "image/png")
        #expect(asset.data == Data("PNGBYTES".utf8))
    }

    @Test func absentAssetIsNil() {
        #expect(ProfileAsset(json: json(#"{"found": false}"#)) == nil)
    }

    @Test func malformedDataURLIsNil() {
        #expect(
            ProfileAsset(json: json(#"{"found": true, "data": "not-a-data-url"}"#)) == nil)
    }
}

@Suite("BotChatPolicy reroute")
struct BotChatPolicyTests {
    @Test func forksAreRerouted() {
        #expect(BotChatPolicy.reroute("/new") == "/compact")
        #expect(BotChatPolicy.reroute("/reset") == "/compact")
        #expect(BotChatPolicy.reroute("  /new fresh start  ") == "/compact")
        #expect(BotChatPolicy.reroute("/NEW") == "/compact")
    }

    @Test func everythingElsePassesThrough() {
        #expect(BotChatPolicy.reroute("/compact") == nil)
        #expect(BotChatPolicy.reroute("/newer things") == nil)
        #expect(BotChatPolicy.reroute("tell me about /new") == nil)
        #expect(BotChatPolicy.reroute("hello") == nil)
        #expect(BotChatPolicy.reroute("") == nil)
    }
}
