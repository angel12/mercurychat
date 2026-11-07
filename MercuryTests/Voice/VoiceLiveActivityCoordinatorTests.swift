import Foundation
import Testing

@MainActor
@Suite("Voice Live Activity coordinator")
struct VoiceLiveActivityCoordinatorTests {
    let start = Date(timeIntervalSince1970: 1_000)

    private func make(_ system: FakeLiveActivitySystem) -> VoiceLiveActivityCoordinator {
        let start = self.start
        return VoiceLiveActivityCoordinator(system: system, now: { start })
    }

    @Test func startsWithTheSourceContentAndEnds() async {
        let system = FakeLiveActivitySystem()
        let c = make(system)
        let source = ObservableActivitySource(.sample())
        c.conversationStarted { source.content }
        #expect(system.starts.count == 1)
        #expect(system.starts.first?.content == .sample())
        #expect(system.starts.first?.startedAt == start)
        #expect(c.currentID == "activity-0")
        c.conversationEnded()
        #expect(c.currentID == nil)
        await c.settled()
        #expect(system.ends == ["activity-0"])
    }

    @Test func sendsOnlyChangedContent() async {
        let system = FakeLiveActivitySystem()
        let c = make(system)
        let source = ObservableActivitySource(.sample())
        c.conversationStarted { source.content }
        source.content = .sample()  // same value
        try? await Task.sleep(for: .milliseconds(50))
        await c.settled()
        #expect(system.updates.isEmpty)
        source.content = .sample(.thinking)
        #expect(await eventually { system.updates.count == 1 })
        #expect(system.updates.first?.content.phase == .thinking)
        source.content = .sample(.speaking, muted: true)
        #expect(await eventually { system.updates.count == 2 })
        #expect(system.updates.last?.content == .sample(.speaking, muted: true))
        c.conversationEnded()
    }

    @Test func noUpdatesAfterTheEnd() async {
        let system = FakeLiveActivitySystem()
        let c = make(system)
        let source = ObservableActivitySource(.sample())
        c.conversationStarted { source.content }
        c.conversationEnded()
        source.content = .sample(.thinking)
        try? await Task.sleep(for: .milliseconds(50))
        await c.settled()
        #expect(system.updates.isEmpty)
        #expect(system.ends == ["activity-0"])
    }

    @Test func aNewStartEndsTheOldActivityFirst() async {
        let system = FakeLiveActivitySystem()
        let c = make(system)
        let first = ObservableActivitySource(.sample(title: "A"))
        let second = ObservableActivitySource(.sample(title: "B"))
        c.conversationStarted { first.content }
        c.conversationStarted { second.content }
        await c.settled()
        #expect(system.starts.map(\.id) == ["activity-0", "activity-1"])
        #expect(system.ends == ["activity-0"])
        first.content = .sample(.thinking, title: "A")  // the old source no longer drives updates
        try? await Task.sleep(for: .milliseconds(50))
        await c.settled()
        #expect(system.updates.isEmpty)
        c.conversationEnded()
    }

    @Test func aFailedStartLeavesNoActivity() async {
        let system = FakeLiveActivitySystem()
        system.startError = FakeLiveActivityStartError()
        let c = make(system)
        let source = ObservableActivitySource(.sample())
        c.conversationStarted { source.content }
        #expect(c.currentID == nil)
        source.content = .sample(.thinking)
        try? await Task.sleep(for: .milliseconds(50))
        c.conversationEnded()
        await c.settled()
        #expect(system.updates.isEmpty)
        #expect(system.ends.isEmpty)
    }

    @Test func launchSweepsEveryActivity() async {
        let system = FakeLiveActivitySystem()
        let c = make(system)
        c.appLaunched()
        await c.settled()
        #expect(system.endAllCount == 1)
    }

    @Test func noSystemIsInert() async {
        let c = VoiceLiveActivityCoordinator(system: nil)
        let source = ObservableActivitySource(.sample())
        c.conversationStarted { source.content }
        #expect(c.currentID == nil)
        c.conversationEnded()
        c.appLaunched()
        await c.settled()
    }
}
