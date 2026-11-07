import Foundation

/// What a conversation's start learned about its call audio.
enum VoiceAudioOutcome: Equatable, Sendable {
    /// CallKit activated the audio session: the mic may arm.
    case activated
    /// No activation within the timeout: run foreground-only.
    case timedOut
    /// The call could not start (or failed): run foreground-only.
    case failed
    /// No call system on this platform, or the call already ended.
    case unavailable
}

/// The platform's call service (CallKit in the app, a fake in tests).
@MainActor protocol VoiceCallSystem: AnyObject {
    var events: (any VoiceCallSystemEvents)? { get set }
    func requestStart(_ call: UUID, displayName: String) async throws
    func requestEnd(_ call: UUID) async throws
    func requestMute(_ call: UUID, muted: Bool) async throws
    func reportEnded(_ call: UUID, failed: Bool)
}

/// What the call service reports back.
@MainActor protocol VoiceCallSystemEvents: AnyObject {
    func systemDidEnd(_ call: UUID)
    func systemDidSetMuted(_ call: UUID, muted: Bool)
    func systemDidActivateAudio()
    func systemDidDeactivateAudio()
    func systemDidReset()
}

/// The host side (AppModel).
@MainActor protocol VoiceCallCenterDelegate: AnyObject {
    func voiceCallEndedBySystem()
    func voiceCallSetMuted(_ muted: Bool)
    func voiceCallAudioSuspended()
    func voiceCallAudioResumed()
}

/// The app's one voice call (spec §1): starts and ends it with the voice
/// conversation, gates the mic on audio activation, keeps mute in sync both
/// ways, and turns the system's end, hold and reset into host calls.
/// Platform-neutral; `system` is nil where there is no call service (macOS).
@MainActor
final class VoiceCallCenter: VoiceCallSystemEvents {
    private let system: (any VoiceCallSystem)?
    private let activationTimeout: Duration
    private let sleep: @Sendable (Duration) async -> Void

    weak var delegate: (any VoiceCallCenterDelegate)?
    private(set) var currentCall: UUID?

    private var outcome: VoiceAudioOutcome?
    private var waiters: [CheckedContinuation<VoiceAudioOutcome, Never>] = []
    private var audioActive = false
    private var systemMuted = false
    /// Mutes this center asked the system for, oldest first: their performs
    /// are echoes, not user actions, and must not reach the controller.
    private var requestedMutes: [Bool] = []
    /// The latest end request still in flight: the next start waits for it,
    /// since CallKit (one call group) can refuse a start while the old call
    /// is still up.
    private var pendingEnd: Task<Void, Never>?
    /// The current call, once the system refused to start it: CallKit never
    /// created it, so later mute and end requests for it are skipped.
    private var failedCall: UUID?

    init(
        system: (any VoiceCallSystem)?, activationTimeout: Duration = .seconds(3),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.system = system
        self.activationTimeout = activationTimeout
        self.sleep = sleep
        system?.events = self
    }

    func startCall(displayName: String) {
        endCall()
        guard let system else { return }
        let call = UUID()
        currentCall = call
        outcome = nil
        audioActive = false
        systemMuted = false
        requestedMutes = []
        let priorEnd = pendingEnd
        Task { [weak self] in
            await priorEnd?.value
            // Superseded while the old call was ending: never start it.
            guard self?.currentCall == call else { return }
            do {
                try await system.requestStart(call, displayName: displayName)
            } catch {
                guard let self, self.currentCall == call else { return }
                self.failedCall = call
                self.resolve(.failed, for: call)
            }
        }
        let timeout = activationTimeout
        let sleep = self.sleep
        Task { [weak self] in
            await sleep(timeout)
            self?.resolve(.timedOut, for: call)
        }
    }

    func waitForAudio() async -> VoiceAudioOutcome {
        guard currentCall != nil else { return .unavailable }
        if let outcome { return outcome }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// The host ended the conversation. Synchronous state change first, so
    /// the system's echo of this end is recognised as stale.
    func endCall() {
        guard let call = currentCall else { return }
        let started = call != failedCall
        clear(releasingWaitersWith: .unavailable)
        guard started, let system else { return }
        pendingEnd = Task { try? await system.requestEnd(call) }
    }

    /// The conversation failed to set up: end the call as failed.
    func reportFailed() {
        guard let call = currentCall else { return }
        clear(releasingWaitersWith: .failed)
        system?.reportEnded(call, failed: true)
    }

    /// The controller's mute changed; mirror it in the system call UI.
    func syncMute(_ muted: Bool) {
        guard let call = currentCall, call != failedCall, muted != systemMuted, let system
        else { return }
        systemMuted = muted
        requestedMutes.append(muted)
        Task { [weak self] in
            do {
                try await system.requestMute(call, muted: muted)
            } catch {
                guard let self, self.currentCall == call else { return }
                if let index = self.requestedMutes.firstIndex(of: muted) {
                    self.requestedMutes.remove(at: index)
                }
                self.systemMuted = !muted
            }
        }
    }

    // MARK: VoiceCallSystemEvents

    func systemDidEnd(_ call: UUID) {
        guard call == currentCall else { return }
        clear(releasingWaitersWith: .unavailable)
        delegate?.voiceCallEndedBySystem()
    }

    func systemDidSetMuted(_ call: UUID, muted: Bool) {
        guard call == currentCall else { return }
        if requestedMutes.first == muted {
            requestedMutes.removeFirst()
            return
        }
        systemMuted = muted
        delegate?.voiceCallSetMuted(muted)
    }

    func systemDidActivateAudio() {
        guard let call = currentCall else { return }
        let wasActive = audioActive
        audioActive = true
        if outcome == nil {
            resolve(.activated, for: call)
        } else if !wasActive {
            delegate?.voiceCallAudioResumed()
        }
    }

    func systemDidDeactivateAudio() {
        guard currentCall != nil, audioActive else { return }
        audioActive = false
        delegate?.voiceCallAudioSuspended()
    }

    func systemDidReset() {
        guard currentCall != nil else { return }
        clear(releasingWaitersWith: .failed)
        delegate?.voiceCallEndedBySystem()
    }

    // MARK: Private

    private func resolve(_ result: VoiceAudioOutcome, for call: UUID) {
        guard call == currentCall, outcome == nil else { return }
        outcome = result
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(returning: result) }
    }

    private func clear(releasingWaitersWith result: VoiceAudioOutcome) {
        currentCall = nil
        failedCall = nil
        outcome = nil
        audioActive = false
        requestedMutes = []
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(returning: result) }
    }
}

extension VoiceCallCenter {
    /// The platform's call service: CallKit on iOS and visionOS, none on macOS.
    static func makeSystem() -> (any VoiceCallSystem)? {
        #if os(iOS) || os(visionOS)
            CallKitVoiceCallSystem()
        #else
            nil
        #endif
    }
}
