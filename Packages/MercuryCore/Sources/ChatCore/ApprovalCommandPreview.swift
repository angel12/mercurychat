import Foundation

/// How much of an approval's command the collapsed card can show. Consent
/// must never be given with part of the command out of view (#103), so when
/// the command could overflow the collapsed card, the card says so and offers
/// an explicit way to read all of it before the choice buttons.
///
/// The estimate is deliberately conservative: it assumes a narrow phone
/// column, so a false "needs expansion" only adds a button, while a false
/// "fits" would hide content.
public struct ApprovalCommandPreview: Equatable, Sendable {
    /// Rendered rows the collapsed card shows before it scrolls.
    public static let collapsedRows = 6
    /// Monospaced characters per row on the narrowest supported width.
    static let columnsPerRow = 32

    /// Newline-separated lines, counting blank ones — blank lines are how a
    /// payload gets pushed below the fold.
    public let lineCount: Int
    /// True when the command may not fit in `collapsedRows` rendered rows.
    public let needsExpansion: Bool

    public init(command: String) {
        // `isNewline` treats "\r\n" as one Character, so CRLF counts once.
        let lines = command.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        lineCount = lines.count
        let rows = lines.reduce(0) { total, line in
            total + max(1, (line.count + Self.columnsPerRow - 1) / Self.columnsPerRow)
        }
        needsExpansion = rows > Self.collapsedRows
    }
}
