#if os(iOS)
    import ActivityKit
    import Foundation

    /// ActivityKit behind `VoiceLiveActivitySystem`. Local updates only: the
    /// app runs for the whole call (background audio + CallKit).
    @MainActor
    final class ActivityKitVoiceLiveActivitySystem: VoiceLiveActivitySystem {
        /// Activities this process started and hasn't ended: a sweep never
        /// ends one of these unless it is passed by id. Not pruned when the
        /// user or system dismisses an activity (bounded by the number of
        /// conversations; harmless).
        private var started: Set<String> = []

        func start(startedAt: Date, content: VoiceActivityContent) throws -> String {
            let activity = try Activity.request(
                attributes: VoiceActivityAttributes(startedAt: startedAt),
                content: ActivityContent(state: content, staleDate: nil),
                pushType: nil)
            started.insert(activity.id)
            return activity.id
        }

        func update(_ id: String, content: VoiceActivityContent) async {
            guard let activity = Self.activity(id) else { return }
            await activity.update(ActivityContent(state: content, staleDate: nil))
        }

        func end(_ id: String) async {
            started.remove(id)
            guard let activity = Self.activity(id) else { return }
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        /// Ends activities this process didn't start (a previous process's,
        /// or ones whose conversation is gone). The coordinator ends its own
        /// current activity by id before it sweeps.
        func endAll() async {
            // The `started` filter is what guarantees a sweep never ends an
            // activity this process started and hasn't ended, even one
            // started after the sweep was requested (the snapshot is taken
            // when the coordinator's queued task runs, so it includes it).
            // Snapshotting the ids synchronously here covers only activities
            // started while the loop below is suspended on `end`.
            let stale = Activity<VoiceActivityAttributes>.activities.map(\.id).filter {
                !started.contains($0)
            }
            for id in stale {
                guard let activity = Self.activity(id) else { continue }
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }

        /// `Activity` isn't `Sendable`: a nonisolated lookup returns a
        /// disconnected value that can be handed to ActivityKit's
        /// `@concurrent` `update`/`end` without crossing the main actor.
        private nonisolated static func activity(_ id: String) -> Activity<VoiceActivityAttributes>? {
            Activity<VoiceActivityAttributes>.activities.first { $0.id == id }
        }
    }
#endif
