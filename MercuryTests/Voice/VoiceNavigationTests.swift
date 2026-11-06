import Foundation
import MercuryKit
@testable import MercuryVoiceEngine
import Testing

/// The Voice tab's navigation (spec §1): the sidebar always offers Voice, a
/// `.voice` route shows the app's one conversation, and leaving the screen
/// keeps it running until an explicit end or a disconnect.
extension SharedMeterTests.VoiceHostTests {
    @MainActor
    @Suite("Voice navigation")
    struct VoiceNavigationTests {
        private var host: SharedMeterTests.VoiceHostTests { .init() }

        @Test func sidebarTabsAlwaysIncludeSessionsAndVoice() async throws {
            let model = AppModel(tokenStore: KeychainTokenStore(service: "com.mercury.tokens.tests"))
            #expect(model.botModeSupported == nil)
            #expect(model.availableSidebarTabs == [.sessions, .voice])
        }

        @Test func switchingToTheBotsTabWhenUnsupportedFallsBackToSessions() async throws {
            let model = AppModel(tokenStore: KeychainTokenStore(service: "com.mercury.tokens.tests"))
            model.sidebarTab = .bots
            #expect(model.resolvedSidebarTab == .sessions)
            model.sidebarTab = .voice
            #expect(model.resolvedSidebarTab == .voice)
        }

        @Test func openVoiceStartsTheHostAndRoutesTheWindow() async throws {
            let h = try await host.connected(ids: [0: "a"])
            let navigation = WindowNavigation()
            h.model.register(navigation)
            let target = host.session("a")

            h.model.openVoice(target, in: navigation)
            #expect(navigation.route == .voice)
            #expect(await eventually { h.model.voiceConversation?.target == target })

            await host.finish(h)
        }

        @Test func navigatingAwayKeepsTheConversation() async throws {
            let h = try await host.connected(ids: [0: "a"])
            let navigation = WindowNavigation()
            h.model.register(navigation)
            let target = host.session("a")

            h.model.openVoice(target, in: navigation)
            #expect(await eventually { h.model.voiceConversation?.target == target })
            let other = try #require(SessionSummary(json: .object(["session_id": .string("stored-x")])))
            navigation.route = .session(other)

            #expect(h.model.voiceConversation?.target == target)

            await host.finish(h)
        }

        @Test func endingVoiceClearsVoiceRoutesOnly() async throws {
            let h = try await host.connected(ids: [0: "a"])
            let showing = WindowNavigation()
            let elsewhere = WindowNavigation()
            h.model.register(showing)
            h.model.register(elsewhere)
            let target = host.session("a")
            h.model.openVoice(target, in: showing)
            #expect(await eventually { h.model.voiceConversation?.target == target })
            let other = try #require(SessionSummary(json: .object(["session_id": .string("stored-x")])))
            elsewhere.route = .session(other)

            h.model.endVoice()

            #expect(showing.route == nil)
            #expect(elsewhere.route == .session(other))
            #expect(h.model.voiceConversation == nil)

            await host.finish(h)
        }

        @Test func switchingTargetsKeepsWindowsOnTheVoiceRoute() async throws {
            let h = try await host.connected(ids: [0: "a", 1: "b"])
            let navigation = WindowNavigation()
            h.model.register(navigation)
            h.model.openVoice(host.session("a"), in: navigation)
            #expect(await eventually { h.model.voiceConversation?.target == host.session("a") })

            h.model.openVoice(host.session("b"), in: navigation)
            #expect(await eventually { h.model.voiceConversation?.target == host.session("b") })
            #expect(navigation.route == .voice)

            await host.finish(h)
        }

        @Test func disconnectClearsVoiceRoutes() async throws {
            let h = try await host.connected(ids: [0: "a"])
            let navigation = WindowNavigation()
            h.model.register(navigation)
            let target = host.session("a")
            h.model.openVoice(target, in: navigation)
            #expect(await eventually { h.model.voiceConversation?.target == target })

            h.model.disconnect()

            #expect(navigation.route == nil)
            #expect(h.model.voiceConversation == nil)

            await host.finish(h)
        }
    }
}
