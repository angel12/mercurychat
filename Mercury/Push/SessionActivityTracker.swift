import Foundation

/// When a chat's session counts as this device's, for Mercury Push claims: it was created here,
/// or a message was sent from here. A created session may learn its stored id only after its
/// first prompt (from `session.info`), so activity seen before the id is known is held until
/// the id arrives, then reported once.
struct SessionActivityTracker: Sendable {
    private var pending = false

    /// Activity happened: the stored id to report now, or nil (held until the id is known).
    mutating func activity(storedID: String?) -> String? {
        guard let storedID else {
            pending = true
            return nil
        }
        pending = false
        return storedID
    }

    /// The chat's stored id changed: the id to report if activity was waiting for it.
    mutating func storedIDChanged(_ storedID: String?) -> String? {
        guard pending, let storedID else { return nil }
        pending = false
        return storedID
    }
}
