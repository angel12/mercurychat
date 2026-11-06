import Foundation

@MainActor
final class FakeVoiceCallSystem: VoiceCallSystem {
    weak var events: (any VoiceCallSystemEvents)?
    private(set) var starts: [(call: UUID, name: String)] = []
    private(set) var ends: [UUID] = []
    private(set) var mutes: [(call: UUID, muted: Bool)] = []
    private(set) var reportedEnded: [(call: UUID, failed: Bool)] = []
    var startError: (any Error)?

    func requestStart(_ call: UUID, displayName: String) async throws {
        starts.append((call, displayName))
        if let startError { throw startError }
    }
    func requestEnd(_ call: UUID) async throws { ends.append(call) }
    func requestMute(_ call: UUID, muted: Bool) async throws { mutes.append((call, muted)) }
    func reportEnded(_ call: UUID, failed: Bool) { reportedEnded.append((call, failed)) }
}

@MainActor
final class RecordingCallDelegate: VoiceCallCenterDelegate {
    var ended = 0
    var muted: [Bool] = []
    var suspended = 0
    var resumed = 0
    func voiceCallEndedBySystem() { ended += 1 }
    func voiceCallSetMuted(_ muted: Bool) { self.muted.append(muted) }
    func voiceCallAudioSuspended() { suspended += 1 }
    func voiceCallAudioResumed() { resumed += 1 }
}

/// Never returns within a test: the activation timeout stays out of the way.
let neverSleep: @Sendable (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }
