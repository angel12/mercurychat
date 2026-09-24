import CoreGraphics
import Observation
import QuartzCore

/// Whether the transcript follows streaming output: scrolling away from the
/// bottom releases the pin, scrolling back (or sending a message, or tapping
/// the jump-to-latest button) restores it.
///
/// Only `isPinnedToBottom` is observable — the body reads it for the
/// jump-to-latest button, and its writes are equality-guarded so the view
/// invalidates only on real pin/unpin transitions. Everything else is
/// `@ObservationIgnored` on purpose: those fields are written on every
/// scrolled point / touch move, and observable per-frame writes would
/// invalidate the whole transcript body 120×/s (measured as app-wide lag).
@MainActor @Observable
final class TranscriptScrollState {
    /// Hysteresis band for the pin: drifting past `unpinDistance` releases it,
    /// but only returning to (nearly) the exact bottom re-engages it. A single
    /// threshold re-pins anyone the auto-scroll just yanked down, which made
    /// the pin impossible to escape mid-stream.
    @ObservationIgnored static let unpinDistance: CGFloat = 80
    /// "At the bottom" must clear the transcript content's 12pt bottom
    /// padding: the scroll anchor sits INSIDE the padded LazyVStack, so a
    /// perfect `scrollTo("bottom", anchor: .bottom)` landing reads ~12pt of
    /// remaining distance, never 0.
    @ObservationIgnored static let repinDistance: CGFloat = 16

    private(set) var isPinnedToBottom = true
    /// True while a deferred scroll is queued so extra requests coalesce.
    @ObservationIgnored var scrollQueued = false
    /// True while a settle chain (post-scrollTo landing correction) runs so
    /// concurrent requests don't stack duplicate chains.
    @ObservationIgnored var settleActive = false
    /// Latest scroll-geometry reading, kept so gesture callbacks (which
    /// can't see geometry) can decide whether the drag ended at the bottom.
    /// Only meaningful once `hasGeometry` is true — before that it is just
    /// the initial 0, NOT a reading.
    @ObservationIgnored var bottomDistance: CGFloat = 0
    /// True after the first scroll-geometry reading. iOS 17 / macOS 14 have
    /// no geometry source for List (`onScrollGeometryChange` is iOS 18 /
    /// macOS 15), so there `bottomDistance` stays at its initial 0 forever —
    /// and reading that 0 as "at the bottom" re-pinned EVERY drag the moment
    /// it ended, snapping the reader straight back down (#105). Without
    /// geometry the coarse bottom-sentinel signal below stands in.
    @ObservationIgnored private(set) var hasGeometry = false
    /// Geometry-less fallback (#105): whether the transcript's zero-height
    /// bottom anchor row is currently realized on screen, as reported by its
    /// onAppear/onDisappear. A List row at the very end can only be on
    /// screen when the content's bottom edge is inside the viewport, so this
    /// is a coarse "at the bottom". Starts false: until the row has reported,
    /// nothing may assume the bottom is visible. Ignored once geometry is
    /// known.
    @ObservationIgnored private(set) var bottomSentinelVisible = false
    @ObservationIgnored var isDragging = false
    /// True while an animated programmatic scroll is in flight. Geometry
    /// reports "far from bottom" mid-animation, which must not unpin —
    /// cleared by the animation's completion or by the user grabbing the view.
    @ObservationIgnored var isAutoScrolling = false

    func setPinned(_ pinned: Bool) {
        guard pinned != isPinnedToBottom else { return }
        isPinnedToBottom = pinned
    }

    /// Unpin the instant a drag starts. Waiting for the geometry callback
    /// loses the race against a queued auto-scroll, which snaps back to the
    /// bottom and re-pins before the "scrolled away" reading lands.
    func dragBegan() {
        isDragging = true
        isAutoScrolling = false
        setPinned(false)
    }

    /// Re-pin only when the drag verifiably ended at the bottom: by geometry
    /// when there is any, else by the bottom sentinel. With neither, stay
    /// unpinned — the explicit paths (Jump to Latest, the user's own send)
    /// still re-pin (#105).
    func dragEnded() {
        isDragging = false
        let atBottom =
            hasGeometry ? bottomDistance < Self.repinDistance : bottomSentinelVisible
        if atBottom { setPinned(true) }
    }

    /// Geometry-less fallback (#105) — see `bottomSentinelVisible`.
    /// Disappearing never unpins on its own: streaming growth pushes the row
    /// off-screen before the deferred auto-scroll catches up, the very
    /// "content grew under me" reading the geometry path has to filter out
    /// with a cool-down. Only user input (drag / wheel) releases the pin.
    /// Reappearing outside a drag re-pins: while unpinned the transcript is
    /// held (no growth), so the bottom coming back into view means the user
    /// scrolled back down — the only way macOS 14 wheel scrolling can re-pin.
    /// Mid-drag the drag end decides instead, as on the geometry path.
    func bottomSentinelVisibilityChanged(_ visible: Bool) {
        guard !hasGeometry else { return }
        bottomSentinelVisible = visible
        if visible, !isDragging { setPinned(true) }
    }

    /// Geometry-less fallback (#105): macOS 14 trackpad / mouse-wheel
    /// scrolling produces no DragGesture, so without this the pin could never
    /// be released there and streaming kept yanking the reader to the
    /// bottom. Called for wheel events that move toward older content.
    func userScrolledTowardOlder() {
        guard !hasGeometry else { return }
        isAutoScrolling = false
        setPinned(false)
    }

    func update(bottomDistance distance: CGFloat, contentGrew: Bool = false) {
        hasGeometry = true
        if contentGrew { lastContentGrowth = CACurrentMediaTime() }
        bottomDistance = distance
        if distance > Self.unpinDistance {
            // Only a reading the USER caused may release the pin: while a
            // programmatic scroll is in flight (isAutoScrolling) the geometry
            // reports mid-seek positions, and while content is growing the
            // lazy layout re-estimates produce far readings out of thin air.
            // The growth flag alone is not enough — appends re-layout in
            // multiple passes, and a second pass reports a jumped distance
            // with the contentHeight UNCHANGED (verified: tool-row appends
            // unpinned the follow mid-stream) — so any reading within a short
            // cool-down of a growth is still treated as content-driven. A
            // real drag unpins synchronously via the gesture, never here.
            guard !isAutoScrolling, !contentGrew,
                CACurrentMediaTime() - lastContentGrowth > 0.15
            else { return }
            setPinned(false)
        } else if distance < Self.repinDistance, !isDragging {
            isAutoScrolling = false
            setPinned(true)
        }
    }

    @ObservationIgnored private var lastContentGrowth: CFTimeInterval = 0
}
