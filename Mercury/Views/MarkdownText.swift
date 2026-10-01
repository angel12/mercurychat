import SwiftUI

/// Renders a (possibly still-growing) assistant markdown string. Block
/// structure comes from `MarkdownBlocks`; inline syntax inside each block goes
/// through AttributedString's inline markdown (streaming-safe — it never
/// throws on partial input, it just falls back to plain text).
struct MarkdownText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        MarkdownBlocksView(blocks: MarkdownBlocks.parse(text), listDepth: 0)
    }

    static func attributed(_ string: String) -> AttributedString {
        var attributed =
            (try? AttributedString(
                markdown: MarkdownBlocks.normalizeInline(string),
                options: AttributedString.MarkdownParsingOptions(
                    allowsExtendedAttributes: false,
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(string)
        linkBareURLs(in: &attributed)
        return attributed
    }

    // NSDataDetector is documented thread-safe for matching.
    private nonisolated(unsafe) static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Models write bare URLs far more often than `<…>` autolinks; make them
    /// tappable unless they're already a link or inside a code span.
    private static func linkBareURLs(in attributed: inout AttributedString) {
        guard let detector = linkDetector else { return }
        let plain = String(attributed.characters)
        for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let url = match.url, let range = Range(match.range, in: attributed) else { continue }
            let styled = attributed[range].runs.contains { run in
                run.link != nil || run.inlinePresentationIntent?.contains(.code) == true
            }
            if !styled { attributed[range].link = url }
        }
    }
}

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlocks.Block]
    /// Nesting depth of the enclosing lists, for the bullet glyph.
    let listDepth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, listDepth: listDepth)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlocks.Block
    let listDepth: Int

    var body: some View {
        switch block {
        case .prose(let text):
            Text(MarkdownText.attributed(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let text):
            Text(MarkdownText.attributed(text))
                .font(Self.headingFont(level))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level <= 2 ? 6 : 2)
                .accessibilityAddTraits(.isHeader)
        case .code(let code, let language):
            CodeBlock(code: code, language: language)
        case .math(let tex):
            // Raw TeX; typesetting it would need a math layout dependency.
            CodeBlock(code: tex, language: "math")
        case .table(let table):
            TableBlock(table: table)
        case .quote(let blocks):
            MarkdownBlocksView(blocks: blocks, listDepth: listDepth)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(.quaternary).frame(width: 3)
                }
        case .callout(let kind, let blocks):
            CalloutBlock(kind: kind, blocks: blocks)
        case .list(let list):
            ListBlock(list: list, depth: listDepth)
        case .image(let alt, let url):
            ImageBlock(alt: alt, url: url)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.semibold)
        case 3: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

private struct ListBlock: View {
    let list: MarkdownList
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(index: index, item: item)
                    MarkdownBlocksView(blocks: item.blocks, listDepth: depth + 1)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(index: Int, item: MarkdownList.Item) -> some View {
        if let checked = item.checked {
            Text(Image(systemName: checked ? "checkmark.square.fill" : "square"))
                .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityLabel(checked ? "Done" : "Not done")
        } else if let start = list.start {
            // The widest number, hidden, keeps every marker the same width.
            ZStack(alignment: .trailing) {
                Text("\(start + list.items.count - 1).").hidden()
                Text("\(start + index).")
            }
            .monospacedDigit()
            .foregroundStyle(.secondary)
        } else {
            Text(["•", "◦", "▪"][depth % 3])
                .foregroundStyle(.secondary)
        }
    }
}

private struct CalloutBlock: View {
    let kind: MarkdownCallout
    let blocks: [MarkdownBlocks.Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
            MarkdownBlocksView(blocks: blocks, listDepth: 0)
        }
        .padding(.vertical, 8)
        .padding(.leading, 13)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                .fill(tint)
                .frame(width: 3)
        }
    }

    private var title: String {
        switch kind {
        case .note: "Note"
        case .tip: "Tip"
        case .important: "Important"
        case .warning: "Warning"
        case .caution: "Caution"
        }
    }

    private var symbol: String {
        switch kind {
        case .note: "info.circle"
        case .tip: "lightbulb"
        case .important: "exclamationmark.bubble"
        case .warning: "exclamationmark.triangle"
        case .caution: "exclamationmark.octagon"
        }
    }

    private var tint: Color {
        switch kind {
        case .note: .blue
        case .tip: .green
        case .important: .purple
        case .warning: .orange
        case .caution: .red
        }
    }
}

private struct ImageBlock: View {
    let alt: String
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 480, maxHeight: 360, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(alt)
            case .failure:
                Link(destination: url) {
                    Label(alt.isEmpty ? url.absoluteString : alt, systemImage: "photo")
                }
                .font(.callout)
            default:
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quinary)
                    .frame(width: 160, height: 120)
                    .overlay(ProgressView())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TableBlock: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, column: column)
                            .fontWeight(.semibold)
                            .gridColumnAlignment(alignment(column))
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    // Unsized so the flexible divider spans the columns
                    // instead of stretching the grid past them.
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            cellView(cell, column: column)
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func cellView(_ cell: String, column: Int) -> some View {
        CappedWidth(maxWidth: 320) {
            Text(MarkdownText.attributed(cell))
                .font(.callout)
                .multilineTextAlignment(textAlignment(column))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        switch table.alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch table.alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Sizes its child to its natural width but never wider than `maxWidth`, so
/// table cells hug short content and wrap long content even inside a
/// horizontal ScrollView (which proposes unlimited width).
private struct CappedWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(capped(proposal)) ?? .zero
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(at: bounds.origin, proposal: capped(proposal))
    }

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? .infinity, maxWidth), height: nil)
    }
}

private struct CodeBlock: View {
    let code: String
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copyToPasteboard(code)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            ScrollView(.horizontal) {
                Text(code)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func copyToPasteboard(_ string: String) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        #else
            UIPasteboard.general.string = string
        #endif
    }
}
