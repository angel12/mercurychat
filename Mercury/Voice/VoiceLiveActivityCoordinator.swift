import Foundation
import Observation
import os

/// The platform's Live Activity service (ActivityKit on iOS, a fake in tests).
@MainActor protocol VoiceLiveActivitySystem: AnyObject {
    /// Starts an activity and returns its id. Throws when Live Activities
    /// are off or the app is over its limit.
    func start(startedAt: Date, content: VoiceActivityContent) throws -> String
    func update(_ id: String, content: VoiceActivityContent) async
    /// Ends the activity and dismisses it immediately.
    func end(_ id: String) async
    /// Ends every voice activity, including one a previous process left.
    func endAll() async
}

/// The voice conversation's Live Activity (sub-project 4, spec §2): started
/// with the conversation, updated when its content changes, ended with it.
/// Platform-neutral; `system` is nil where there are no Live Activities.
@MainActor
final class VoiceLiveActivityCoordinator {
    private static let log = Logger(subsystem: "com.spencermcguire.mercurychat", category: "voice-activity")

    private let system: (any VoiceLiveActivitySystem)?
    private let now: @MainActor () -> Date
    private(set) var currentID: String?
    private var lastContent: VoiceActivityContent?
    /// Bumped on every start and end, so a superseded observation stops.
    private var generation = 0
    /// System calls run one at a time, in order: no update after its end.
    private var queue: Task<Void, Never>?

    init(system: (any VoiceLiveActivitySystem)?, now: @escaping @MainActor () -> Date = { Date() }) {
        self.system = system
        self.now = now
    }

    /// A conversation started (the app is in front). `content` reads the
    /// live host; it is observed until the conversation ends.
    func conversationStarted(content: @escaping @MainActor @Sendable () -> VoiceActivityContent?) {
        conversationEnded()
        guard let system, let initial = content() else { return }
        generation += 1
        do {
            currentID = try system.start(startedAt: now(), content: initial)
            lastContent = initial
        } catch {
            // The conversation and its call don't depend on the activity.
            Self.log.error("Live Activity didn't start: \(error.localizedDescription, privacy: .public)")
            return
        }
        observe(content, generation: generation)
    }

    /// The conversation ended (any path). Synchronous: later changes are dropped.
    func conversationEnded() {
        generation += 1
        guard let id = currentID, let system else { return }
        currentID = nil
        lastContent = nil
        enqueue { await system.end(id) }
    }

    /// End every voice activity: the launch sweep, and an intent with no conversation.
    func endAll() {
        conversationEnded()
        guard let system else { return }
        enqueue { await system.endAll() }
    }

    /// No voice conversation survives a relaunch.
    func appLaunched() { endAll() }

    /// Waits for the queued system calls (tests).
    func settled() async { await queue?.value }

    // MARK: Private

    private func contentChanged(_ content: VoiceActivityContent) {
        guard let id = currentID, let system, content != lastContent else { return }
        lastContent = content
        enqueue { await system.update(id, content: content) }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let prior = queue
        queue = Task { @MainActor in
            await prior?.value
            await work()
        }
    }

    private func observe(
        _ source: @escaping @MainActor @Sendable () -> VoiceActivityContent?, generation: Int
    ) {
        guard generation == self.generation else { return }
        let value = withObservationTracking {
            source()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe(source, generation: generation) }
        }
        if let value { contentChanged(value) }
    }
}

extension VoiceLiveActivityCoordinator {
    /// The platform's Live Activity service: ActivityKit on iOS, none elsewhere.
    static func makeSystem() -> (any VoiceLiveActivitySystem)? {
        #if os(iOS)
            ActivityKitVoiceLiveActivitySystem()
        #else
            nil
        #endif
    }
}
