import Foundation
import MercuryKit

extension SessionSummary {
    /// A session the backend's cron scheduler started. Every cron run gets
    /// the id `cron_<jobId>_<timestamp>` (hermes `cron/scheduler.py`), the
    /// same prefix the backend itself uses to find a job's sessions.
    var isScheduled: Bool { storedID.hasPrefix("cron_") }
}

/// "Hide scheduled sessions" (Settings › General): keeps cron runs out of
/// the sidebar's recent and workspace session lists.
enum ScheduledSessionFilter {
    static let preferenceKey = "hideScheduledSessions"

    static func isHiding(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: preferenceKey)
    }

    /// The sessions to show, in order, at most `limit` of them.
    static func visible(
        _ sessions: [SessionSummary], hidingScheduled: Bool, limit: Int = .max
    ) -> [SessionSummary] {
        let kept = hidingScheduled ? sessions.filter { !$0.isScheduled } : sessions
        return Array(kept.prefix(limit))
    }

    /// How many rows to fetch to fill `display` rows: hourly crons can bury
    /// the human sessions, so hiding them fetches a deeper page.
    static func fetchLimit(display: Int, hidingScheduled: Bool) -> Int {
        hidingScheduled ? display * 4 : display
    }
}
