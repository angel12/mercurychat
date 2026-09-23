import Foundation
import MercuryKit

/// The canonical Bot Chat is a forever-chat: `/new` (or `/reset`) would fork
/// the relationship into a scratch session — the one thing Bot Mode promises
/// never happens. Those commands (and an explicit `/compact`) run REAL
/// compression via the `session.compress` RPC instead — `prompt.submit`
/// treats slash text as an ordinary message, so rewriting the string alone
/// would only send "/compact" to the model.
///
/// MercuryKit owns `BotChatPolicy`'s upstream-defined identity
/// (`canonicalTitle`, `isCanonicalRow`); this composer rule is app UI, so it
/// lives here. Public because the app target calls it.
extension BotChatPolicy {
    /// True when `text` must run compression instead of being submitted as a
    /// prompt inside a canonical Bot Chat. Only the leading command token
    /// matters — arguments (e.g. `/new some title`) don't rescue a fork.
    public static func isCompactCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init)
        switch command?.lowercased() {
        case "/new", "/reset", "/compact":
            return true
        default:
            return false
        }
    }
}
