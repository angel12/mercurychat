import Foundation
import Testing

// NOTE: no `import Mercury` — the app has no module; this test bundle
// compiles Mercury/Views/TranscriptScrollState.swift directly (project.yml).

/// Pin bookkeeping, especially on the path WITHOUT a scroll-geometry source
/// (#105): iOS 17 / macOS 14 have no `onScrollGeometryChange`, so
/// `bottomDistance` is never written and must not be read as "at the bottom".
@MainActor
@Suite("Transcript scroll pinning")
struct TranscriptScrollStateTests {
    @Test func dragEndWithoutGeometryDoesNotRepin() {
        let scroll = TranscriptScrollState()
        scroll.dragBegan()
        #expect(!scroll.isPinnedToBottom)
        scroll.dragEnded()
        #expect(!scroll.isPinnedToBottom)
    }

    @Test func dragEndWithGeometryNearBottomRepins() {
        let scroll = TranscriptScrollState()
        scroll.update(bottomDistance: 200)
        scroll.dragBegan()
        scroll.update(bottomDistance: 4)
        scroll.dragEnded()
        #expect(scroll.isPinnedToBottom)
    }

    @Test func dragEndWithGeometryAwayFromBottomStaysUnpinned() {
        let scroll = TranscriptScrollState()
        scroll.update(bottomDistance: 4)
        scroll.dragBegan()
        scroll.update(bottomDistance: 300)
        scroll.dragEnded()
        #expect(!scroll.isPinnedToBottom)
    }

    @Test func explicitPinStillWorksWithoutGeometry() {
        // Jump to Latest and the user's own send both call setPinned(true).
        let scroll = TranscriptScrollState()
        scroll.dragBegan()
        scroll.dragEnded()
        scroll.setPinned(true)
        #expect(scroll.isPinnedToBottom)
    }

    // MARK: Coarse fallback (no geometry): bottom sentinel + wheel

    @Test func dragEndWithoutGeometryRepinsWhenBottomSentinelVisible() {
        let scroll = TranscriptScrollState()
        scroll.bottomSentinelVisibilityChanged(true)
        scroll.dragBegan()
        scroll.dragEnded()
        #expect(scroll.isPinnedToBottom)
    }

    @Test func dragEndWithoutGeometryStaysUnpinnedAfterSentinelLeft() {
        let scroll = TranscriptScrollState()
        scroll.bottomSentinelVisibilityChanged(true)
        scroll.dragBegan()
        scroll.bottomSentinelVisibilityChanged(false)
        scroll.dragEnded()
        #expect(!scroll.isPinnedToBottom)
    }

    @Test func sentinelDisappearingNeverUnpinsByItself() {
        // Streaming growth pushes the sentinel off-screen before the deferred
        // auto-scroll catches up — that must not release the pin.
        let scroll = TranscriptScrollState()
        scroll.bottomSentinelVisibilityChanged(true)
        scroll.bottomSentinelVisibilityChanged(false)
        #expect(scroll.isPinnedToBottom)
    }

    @Test func sentinelReappearingRepinsOnlyOutsideADrag() {
        let scroll = TranscriptScrollState()
        scroll.dragBegan()
        scroll.bottomSentinelVisibilityChanged(true)
        #expect(!scroll.isPinnedToBottom)  // mid-drag: drag end decides
        scroll.dragEnded()
        #expect(scroll.isPinnedToBottom)

        scroll.userScrolledTowardOlder()
        #expect(!scroll.isPinnedToBottom)
        scroll.bottomSentinelVisibilityChanged(false)
        scroll.bottomSentinelVisibilityChanged(true)
        #expect(scroll.isPinnedToBottom)
    }

    @Test func wheelTowardOlderUnpinsAndCancelsAutoScroll() {
        let scroll = TranscriptScrollState()
        scroll.isAutoScrolling = true
        scroll.userScrolledTowardOlder()
        #expect(!scroll.isPinnedToBottom)
        #expect(!scroll.isAutoScrolling)
    }

    @Test func fallbackSignalsAreIgnoredOnceGeometryIsKnown() {
        let scroll = TranscriptScrollState()
        scroll.update(bottomDistance: 300)
        scroll.setPinned(false)
        scroll.bottomSentinelVisibilityChanged(true)
        #expect(!scroll.isPinnedToBottom)
        scroll.setPinned(true)
        scroll.userScrolledTowardOlder()
        #expect(scroll.isPinnedToBottom)
        scroll.dragBegan()
        scroll.dragEnded()  // geometry says 300pt up: no repin
        #expect(!scroll.isPinnedToBottom)
    }
}
