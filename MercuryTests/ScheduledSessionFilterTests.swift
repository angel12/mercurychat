import Foundation
import MercuryKit
import Testing

/// "Hide scheduled sessions" (Settings › General): cron runs are recognised
/// by the backend's `cron_<jobId>_<timestamp>` session id, and hiding them
/// must not leave the recents list short.
@Suite("Scheduled session filter")
struct ScheduledSessionFilterTests {
    private func session(_ id: String) -> SessionSummary {
        SessionSummary(json: .object(["session_id": .string(id)]))!
    }

    @Test("cron run ids are scheduled; other ids are not")
    func recognisesCronRuns() {
        #expect(session("cron_daily-digest_20261107_090000").isScheduled)
        #expect(!session("20261107_090000_abc123").isScheduled)
        #expect(!session("cronjob_notes").isScheduled)
        #expect(!session("my_cron_session").isScheduled)
    }

    @Test("showing everything keeps order and trims to the limit")
    func showAll() {
        let sessions = ["a", "cron_j_1", "b", "c"].map(session)
        let visible = ScheduledSessionFilter.visible(sessions, hidingScheduled: false, limit: 3)
        #expect(visible.map(\.id) == ["a", "cron_j_1", "b"])
    }

    @Test("hiding drops cron runs before trimming to the limit")
    func hideScheduled() {
        let sessions = ["cron_j_1", "a", "cron_j_2", "b", "c", "d"].map(session)
        let visible = ScheduledSessionFilter.visible(sessions, hidingScheduled: true, limit: 3)
        #expect(visible.map(\.id) == ["a", "b", "c"])
    }

    @Test("hiding over-fetches so the list can still fill")
    func fetchLimit() {
        #expect(ScheduledSessionFilter.fetchLimit(display: 30, hidingScheduled: false) == 30)
        #expect(ScheduledSessionFilter.fetchLimit(display: 30, hidingScheduled: true) > 30)
    }

    @Test("the preference defaults to off")
    func defaultsOff() {
        let defaults = UserDefaults(suiteName: "ScheduledSessionFilterTests-\(UUID())")!
        #expect(!ScheduledSessionFilter.isHiding(in: defaults))
        defaults.set(true, forKey: ScheduledSessionFilter.preferenceKey)
        #expect(ScheduledSessionFilter.isHiding(in: defaults))
    }
}
