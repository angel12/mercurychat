import Foundation
import Testing

@MainActor
@Suite("Voice call center")
struct VoiceCallCenterTests {
    func make(timeout: @escaping @Sendable (Duration) async -> Void = neverSleep)
        -> (VoiceCallCenter, FakeVoiceCallSystem, RecordingCallDelegate)
    {
        let system = FakeVoiceCallSystem()
        let center = VoiceCallCenter(system: system, sleep: timeout)
        let delegate = RecordingCallDelegate()
        center.delegate = delegate
        return (center, system, delegate)
    }

    @Test func activationOpensTheGate() async {
        let (center, system, _) = make()
        center.startCall(displayName: "Plan")
        let wait = Task { await center.waitForAudio() }
        await Task.yield()
        center.systemDidActivateAudio()
        #expect(await wait.value == .activated)
        #expect(system.starts.map(\.name) == ["Plan"])
    }

    @Test func timeoutOpensTheGate() async {
        let (center, _, _) = make(timeout: { _ in })
        center.startCall(displayName: "Plan")
        #expect(await center.waitForAudio() == .timedOut)
    }

    @Test func failedStartOpensTheGate() async {
        let (center, system, _) = make()
        system.startError = CocoaError(.userCancelled)
        center.startCall(displayName: "Plan")
        #expect(await center.waitForAudio() == .failed)
    }

    @Test func noSystemIsUnavailable() async {
        let center = VoiceCallCenter(system: nil)
        center.startCall(displayName: "Plan")
        #expect(await center.waitForAudio() == .unavailable)
        #expect(center.currentCall == nil)
    }

    @Test func systemEndNotifiesOnceAndAppEndDoesNotLoop() async throws {
        let (center, system, delegate) = make()
        center.startCall(displayName: "Plan")
        let call = try #require(center.currentCall)
        center.systemDidEnd(call)
        #expect(delegate.ended == 1)
        center.endCall()  // the host's endVoice echo
        try await Task.sleep(for: .milliseconds(50))
        #expect(system.ends.isEmpty)
    }

    @Test func appEndRequestsOneEndAndIgnoresItsEcho() async throws {
        let (center, system, delegate) = make()
        center.startCall(displayName: "Plan")
        let call = try #require(center.currentCall)
        center.endCall()
        #expect(await eventually { system.ends == [call] })
        center.systemDidEnd(call)  // CallKit performs our own end action
        #expect(delegate.ended == 0)
    }

    @Test func endReleasesAWaitingBegin() async {
        let (center, _, _) = make()
        center.startCall(displayName: "Plan")
        let wait = Task { await center.waitForAudio() }
        await Task.yield()
        center.endCall()
        #expect(await wait.value == .unavailable)
    }

    @Test func muteSyncBothWaysWithoutEcho() async throws {
        let (center, system, delegate) = make()
        center.startCall(displayName: "Plan")
        let call = try #require(center.currentCall)
        center.syncMute(true)
        #expect(await eventually { system.mutes.count == 1 })
        center.systemDidSetMuted(call, muted: true)  // echo of our request
        #expect(delegate.muted.isEmpty)
        center.systemDidSetMuted(call, muted: false)  // the user, on the lock screen
        #expect(delegate.muted == [false])
        center.syncMute(false)  // the controller reporting that change
        try await Task.sleep(for: .milliseconds(50))
        #expect(system.mutes.count == 1)
    }

    @Test func staleCallEventsAreIgnored() async {
        let (center, _, delegate) = make()
        center.startCall(displayName: "Plan")
        center.systemDidEnd(UUID())
        center.systemDidSetMuted(UUID(), muted: true)
        #expect(delegate.ended == 0)
        #expect(delegate.muted.isEmpty)
    }

    @Test func deactivateThenActivateSuspendsAndResumes() async {
        let (center, _, delegate) = make()
        center.startCall(displayName: "Plan")
        center.systemDidActivateAudio()
        #expect(await center.waitForAudio() == .activated)
        center.systemDidDeactivateAudio()
        center.systemDidActivateAudio()
        #expect(delegate.suspended == 1)
        #expect(delegate.resumed == 1)
    }

    @Test func reportFailedEndsTheCallAsFailed() throws {
        let (center, system, _) = make()
        center.startCall(displayName: "Plan")
        let call = try #require(center.currentCall)
        center.reportFailed()
        #expect(system.reportedEnded.map(\.call) == [call])
        #expect(system.reportedEnded.first?.failed == true)
        #expect(center.currentCall == nil)
    }

    @Test func resetEndsTheConversation() {
        let (center, _, delegate) = make()
        center.startCall(displayName: "Plan")
        center.systemDidReset()
        #expect(delegate.ended == 1)
    }
}
