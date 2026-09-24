import Foundation

/// The bot editor's avatar choice, with each image load owned by the pick
/// that started it (#107). Without the ownership, a slow load of photo A
/// finishing after photo B overwrote B, a load still running when Remove was
/// tapped brought the removed image back (and Save uploaded it), Save during
/// a load dismissed without the chosen photo, and a stale failure showed
/// "Couldn't read that image." over a later successful pick.
///
/// `pick()` hands out a token; only the latest token's `loadFinished` counts.
/// `remove()` and `cancelPending()` retire the outstanding token, so a load
/// finishing after them is ignored.
///
/// Public because the app target calls it.
public struct AvatarSelection: Equatable, Sendable {
    /// nil = untouched; .some(nil) = clear; .some(data) = replace.
    public private(set) var change: Data??
    /// True when the current pick's image couldn't be read. A new pick or
    /// Remove resets it.
    public private(set) var loadFailed = false
    private var pendingToken: Int?
    private var nextToken = 0

    public init() {}

    /// False while the current pick is still loading: saving then would
    /// silently drop the chosen photo.
    public var canSave: Bool { pendingToken == nil }

    /// Start loading a new pick. Pass the returned token to `loadFinished`.
    public mutating func pick() -> Int {
        nextToken += 1
        pendingToken = nextToken
        loadFailed = false
        return nextToken
    }

    /// A load completed: `jpeg` is the encoded image, or nil if it couldn't
    /// be read. Ignored unless `token` is the current pick's.
    public mutating func loadFinished(_ token: Int, jpeg: Data?) {
        guard token == pendingToken else { return }
        pendingToken = nil
        if let jpeg {
            change = .some(jpeg)
        } else {
            loadFailed = true
        }
    }

    /// Clear the avatar. Wins over any load still in flight.
    public mutating func remove() {
        pendingToken = nil
        loadFailed = false
        change = .some(nil)
    }

    /// The picker dropped its selection without a new one: stop waiting on
    /// the pending load and keep whatever change was already made.
    public mutating func cancelPending() {
        pendingToken = nil
    }
}
