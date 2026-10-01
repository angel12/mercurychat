import Foundation

/// A GFM pipe table: header cells, per-column alignment, and body rows
/// (padded/trimmed to the header's width). Cells hold raw inline markdown.
struct MarkdownTable: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }

    var header: [String]
    var alignments: [Alignment]
    var rows: [[String]]
}

/// A bulleted or numbered list; each item holds its own blocks, so nested
/// lists, code, and quotes inside items come for free.
struct MarkdownList: Equatable {
    struct Item: Equatable {
        /// nil for a plain item; the box state for a `- [ ]` / `- [x]` task.
        var checked: Bool?
        var blocks: [MarkdownBlocks.Block]
    }

    /// The first number of an ordered list; nil for a bulleted one.
    var start: Int?
    var items: [Item]
}

/// GitHub alert kinds (`> [!NOTE]` …), which the Hermes desktop prompt tells
/// the model it can use.
enum MarkdownCallout: String, Equatable, CaseIterable {
    case note, tip, important, warning, caution
}

/// Block-level parse of a (possibly still-growing) markdown string into the
/// pieces `MarkdownText` renders: a line-based, recursive subset of
/// CommonMark + GFM covering what the agent is told it can emit. Inline
/// syntax (emphasis, code spans, links) is left in the strings for
/// AttributedString's inline parser. Pure, so it's testable without UI, and
/// total — any input parses, which keeps mid-stream text rendering sanely.
enum MarkdownBlocks {
    enum Block: Equatable {
        case prose(String)
        case heading(level: Int, text: String)
        case code(String, language: String?)
        /// A `$$…$$` / `\[…\]` display-math block, as raw TeX.
        case math(String)
        case table(MarkdownTable)
        case quote([Block])
        case callout(MarkdownCallout, [Block])
        case list(MarkdownList)
        /// A paragraph that is a single remote image.
        case image(alt: String, url: URL)
        case rule
    }

    static func parse(_ text: String) -> [Block] {
        // isNewline, not "\n": "\r\n" is a single Character in Swift.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.replacingOccurrences(of: "\t", with: "    ") }
        return parse(lines: lines)
    }

    /// Inline-text cleanup applied before AttributedString parsing: models
    /// put `<br>` in table cells for line breaks.
    static func normalizeInline(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
    }

    private static func parse(lines: [String]) -> [Block] {
        var parser = Parser(lines: lines)
        return parser.run()
    }

    // MARK: - Parser

    private struct Parser {
        let lines: [String]
        var i = 0
        var blocks: [Block] = []
        var paragraph: [String] = []

        init(lines: [String]) { self.lines = lines }

        mutating func run() -> [Block] {
            while i < lines.count {
                let line = lines[i]
                if isBlank(line) {
                    flushParagraph()
                    i += 1
                } else if let fence = Fence(line) {
                    flushParagraph()
                    parseFence(fence)
                } else if let math = MathOpener(line) {
                    flushParagraph()
                    parseMath(math)
                } else if let heading = atxHeading(line) {
                    flushParagraph()
                    blocks.append(heading)
                    i += 1
                } else if !paragraph.isEmpty, let level = setextLevel(line) {
                    let text = paragraph.joined(separator: " ")
                    paragraph = []
                    blocks.append(.heading(level: level, text: text))
                    i += 1
                } else if isRule(line) {
                    flushParagraph()
                    blocks.append(.rule)
                    i += 1
                } else if let table = tableHead(at: i) {
                    flushParagraph()
                    parseTable(header: table.header, alignments: table.alignments)
                } else if quoteContent(line) != nil {
                    flushParagraph()
                    parseQuote()
                } else if let marker = ListMarker(line),
                    paragraph.isEmpty || marker.canInterruptParagraph
                {
                    flushParagraph()
                    parseList(first: marker)
                } else {
                    paragraph.append(String(line.drop(while: { $0 == " " })))
                    i += 1
                }
            }
            flushParagraph()
            return blocks
        }

        private mutating func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: "\n")
            paragraph = []
            blocks.append(standaloneImage(text) ?? .prose(text))
        }

        // MARK: Code and math

        private mutating func parseFence(_ fence: Fence) {
            i += 1
            var code: [String] = []
            while i < lines.count {
                let line = lines[i]
                i += 1
                if fence.closes(line) {
                    break
                }
                code.append(String(line.dropFirst(min(indentation(line), fence.indent))))
            }
            // An unterminated fence (mid-stream) is a code block still growing.
            blocks.append(.code(code.joined(separator: "\n"), language: fence.language))
        }

        private mutating func parseMath(_ opener: MathOpener) {
            if let oneLine = opener.oneLine {
                blocks.append(.math(oneLine))
                i += 1
                return
            }
            var tex: [String] = opener.firstLine.isEmpty ? [] : [opener.firstLine]
            i += 1
            while i < lines.count {
                let line = lines[i].trimmingCharacters(in: .whitespaces)
                i += 1
                if line.hasSuffix(opener.closer) {
                    let last = line.dropLast(opener.closer.count).trimmingCharacters(in: .whitespaces)
                    if !last.isEmpty { tex.append(last) }
                    break
                }
                tex.append(line)
            }
            blocks.append(.math(tex.joined(separator: "\n")))
        }

        // MARK: Tables

        /// A table needs a header row and a delimiter row with the same column
        /// count, so a header that's still streaming (no delimiter yet) renders
        /// as prose until the delimiter lands.
        private func tableHead(at index: Int) -> (header: [String], alignments: [MarkdownTable.Alignment])? {
            guard index + 1 < lines.count, lines[index].contains("|"),
                let alignments = delimiterAlignments(lines[index + 1])
            else { return nil }
            let header = cells(of: lines[index])
            guard alignments.count == header.count else { return nil }
            return (header, alignments)
        }

        private mutating func parseTable(header: [String], alignments: [MarkdownTable.Alignment]) {
            i += 2
            var rows: [[String]] = []
            while i < lines.count, lines[i].contains("|"), !isBlank(lines[i]) {
                var row = cells(of: lines[i])
                if row.count < header.count {
                    row += Array(repeating: "", count: header.count - row.count)
                } else if row.count > header.count {
                    row = Array(row.prefix(header.count))
                }
                rows.append(row)
                i += 1
            }
            blocks.append(.table(MarkdownTable(header: header, alignments: alignments, rows: rows)))
        }

        // MARK: Quotes

        private mutating func parseQuote() {
            var inner: [String] = []
            while i < lines.count {
                let line = lines[i]
                if let content = quoteContent(line) {
                    inner.append(content)
                } else if let last = inner.last, !isBlank(last), !isBlank(line), !startsBlock(line) {
                    // Lazy continuation of the quote's paragraph.
                    inner.append(line)
                } else {
                    break
                }
                i += 1
            }
            if let (kind, rest) = callout(inner) {
                blocks.append(.callout(kind, MarkdownBlocks.parse(lines: rest)))
            } else {
                blocks.append(.quote(MarkdownBlocks.parse(lines: inner)))
            }
        }

        /// `[!NOTE]` on the quote's first line marks a GitHub alert; text after
        /// the marker on that line starts the body.
        private func callout(_ inner: [String]) -> (MarkdownCallout, [String])? {
            guard let first = inner.first?.trimmingCharacters(in: .whitespaces),
                first.hasPrefix("[!"), let close = first.firstIndex(of: "]")
            else { return nil }
            let name = first[first.index(first.startIndex, offsetBy: 2)..<close].lowercased()
            guard let kind = MarkdownCallout(rawValue: name) else { return nil }
            let tail = first[first.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return (kind, (tail.isEmpty ? [] : [tail]) + inner.dropFirst())
        }

        // MARK: Lists

        private mutating func parseList(first: ListMarker) {
            var items: [MarkdownList.Item] = []
            var marker = first
            while true {
                var itemLines = [marker.content]
                i += 1
                while i < lines.count {
                    let line = lines[i]
                    if isBlank(line) {
                        // Blank lines stay in the item only if indented content follows.
                        var next = i + 1
                        while next < lines.count, isBlank(lines[next]) { next += 1 }
                        guard next < lines.count, indentation(lines[next]) >= marker.contentIndent
                        else { break }
                        itemLines += Array(repeating: "", count: next - i)
                        i = next
                        continue
                    }
                    let indent = indentation(line)
                    if indent >= marker.contentIndent {
                        itemLines.append(String(line.dropFirst(marker.contentIndent)))
                    } else if let sub = ListMarker(line), sub.indent > marker.indent, !isRule(line) {
                        // A sub-list indented short of the content column (two
                        // spaces under "1." is common model output).
                        itemLines.append(String(line.dropFirst(indent)))
                    } else if let last = itemLines.last, !isBlank(last), !startsBlock(line) {
                        // Lazy continuation of the item's paragraph.
                        itemLines.append(String(line.dropFirst(indent)))
                    } else {
                        break
                    }
                    i += 1
                }
                items.append(listItem(itemLines))

                // A sibling marker (possibly after blank lines) continues the list.
                var next = i
                while next < lines.count, isBlank(lines[next]) { next += 1 }
                guard next < lines.count, !isRule(lines[next]),
                    let sibling = ListMarker(lines[next]), sibling.continues(first),
                    sibling.indent < marker.contentIndent
                else { break }
                i = next
                marker = sibling
            }
            blocks.append(.list(MarkdownList(start: first.number, items: items)))
        }

        private func listItem(_ itemLines: [String]) -> MarkdownList.Item {
            var itemLines = itemLines
            var checked: Bool?
            let head = itemLines[0]
            for (box, state) in [("[ ]", false), ("[x]", true), ("[X]", true)]
            where head.hasPrefix(box) && (head.count == 3 || head.dropFirst(3).first == " ") {
                checked = state
                itemLines[0] = String(head.dropFirst(3).drop(while: { $0 == " " }))
            }
            return MarkdownList.Item(checked: checked, blocks: MarkdownBlocks.parse(lines: itemLines))
        }

        // MARK: Line classification

        /// Whether `line` would start a non-paragraph block (so it can't be a
        /// lazy continuation line).
        private func startsBlock(_ line: String) -> Bool {
            Fence(line) != nil || MathOpener(line) != nil || atxHeading(line) != nil
                || isRule(line) || quoteContent(line) != nil || ListMarker(line) != nil
        }

        private func atxHeading(_ line: String) -> Block? {
            guard indentation(line) <= 3 else { return nil }
            let rest = line.drop(while: { $0 == " " })
            let hashes = rest.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(hashes) else { return nil }
            let after = rest.dropFirst(hashes)
            guard after.isEmpty || after.first == " " else { return nil }
            var text = after.trimmingCharacters(in: .whitespaces)
            // Optional closing hashes: "## Title ##".
            let closing = text.reversed().prefix(while: { $0 == "#" }).count
            if closing > 0, closing == text.count || text.dropLast(closing).last == " " {
                text = text.dropLast(closing).trimmingCharacters(in: .whitespaces)
            }
            return .heading(level: hashes, text: text)
        }

        private func setextLevel(_ line: String) -> Int? {
            guard indentation(line) <= 3 else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "=" }) { return 1 }
            // Two or more, so a lone "-" mid-stream (a list item about to
            // arrive) doesn't flash the paragraph into a heading.
            if trimmed.count >= 2, trimmed.allSatisfy({ $0 == "-" }) { return 2 }
            return nil
        }

        private func isRule(_ line: String) -> Bool {
            guard indentation(line) <= 3 else { return false }
            let chars = line.filter { $0 != " " }
            guard let first = chars.first, "-*_".contains(first) else { return false }
            return chars.count >= 3 && chars.allSatisfy { $0 == first }
        }

        private func quoteContent(_ line: String) -> String? {
            guard indentation(line) <= 3 else { return nil }
            let rest = line.drop(while: { $0 == " " })
            guard rest.first == ">" else { return nil }
            let content = rest.dropFirst()
            return String(content.first == " " ? content.dropFirst() : content)
        }

        private func standaloneImage(_ text: String) -> Block? {
            let pattern = /^!\[([^\]]*)\]\(<?(https?:\/\/[^)\s>]+)>?(?:\s+"[^"]*")?\)$/
            guard let match = text.trimmingCharacters(in: .whitespaces).wholeMatch(of: pattern),
                let url = URL(string: String(match.2))
            else { return nil }
            return .image(alt: String(match.1), url: url)
        }

        /// Alignments if `line` is a delimiter row (`|---|:--:|--:|`), else nil.
        private func delimiterAlignments(_ line: String) -> [MarkdownTable.Alignment]? {
            guard line.contains("-") else { return nil }
            let parts = cells(of: line)
            // A lone `---` with no pipe is a thematic break, not a table.
            guard !parts.isEmpty, parts.count > 1 || line.contains("|") else { return nil }
            var alignments: [MarkdownTable.Alignment] = []
            for part in parts {
                let leadingColon = part.hasPrefix(":")
                let trailingColon = part.hasSuffix(":") && part.count > 1
                let dashes = part.dropFirst(leadingColon ? 1 : 0).dropLast(trailingColon ? 1 : 0)
                guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
                switch (leadingColon, trailingColon) {
                case (true, true): alignments.append(.center)
                case (false, true): alignments.append(.trailing)
                default: alignments.append(.leading)
                }
            }
            return alignments
        }

        /// Split a row on unescaped pipes, dropping the optional outer pipes and
        /// unescaping `\|` inside cells.
        private func cells(of line: String) -> [String] {
            var row = line.trimmingCharacters(in: .whitespaces)[...]
            if row.hasPrefix("|") { row = row.dropFirst() }
            if row.hasSuffix("|") && !row.hasSuffix("\\|") { row = row.dropLast() }

            var cells: [String] = []
            var current = ""
            var escaped = false
            for char in row {
                if escaped {
                    current += char == "|" ? "|" : "\\\(char)"
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "|" {
                    cells.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(char)
                }
            }
            if escaped { current += "\\" }
            cells.append(current.trimmingCharacters(in: .whitespaces))
            return cells
        }
    }

    // MARK: - Line openers

    /// An opening ``` or ~~~ fence (three or more), with its indent and info string.
    private struct Fence {
        let char: Character
        let count: Int
        let indent: Int
        let language: String?

        init?(_ line: String) {
            indent = indentation(line)
            guard indent <= 3 else { return nil }
            let rest = line.drop(while: { $0 == " " })
            guard let first = rest.first, first == "`" || first == "~" else { return nil }
            count = rest.prefix(while: { $0 == first }).count
            guard count >= 3 else { return nil }
            let info = rest.dropFirst(count).trimmingCharacters(in: .whitespaces)
            if first == "`" && info.contains("`") { return nil }
            char = first
            let word = info.split(separator: " ").first.map(String.init)
            language = word?.isEmpty == false ? word : nil
        }

        func closes(_ line: String) -> Bool {
            guard indentation(line) <= 3 else { return false }
            let rest = line.trimmingCharacters(in: .whitespaces)
            return rest.count >= count && rest.allSatisfy { $0 == char }
        }
    }

    /// `$$` or `\[` opening a display-math block. `oneLine` is set for the
    /// whole block on one line (`$$x$$`).
    private struct MathOpener {
        let closer: String
        let firstLine: String
        let oneLine: String?

        init?(_ line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let opener: String
            if trimmed.hasPrefix("$$") {
                (opener, closer) = ("$$", "$$")
            } else if trimmed.hasPrefix("\\[") {
                (opener, closer) = ("\\[", "\\]")
            } else {
                return nil
            }
            let body = trimmed.dropFirst(opener.count)
            if body.count >= closer.count, body.hasSuffix(closer) {
                oneLine = body.dropLast(closer.count).trimmingCharacters(in: .whitespaces)
                firstLine = ""
            } else {
                oneLine = nil
                firstLine = body.trimmingCharacters(in: .whitespaces)
            }
        }
    }

    /// A bullet (`-`, `*`, `+`) or ordered (`1.`, `1)`) list marker.
    private struct ListMarker {
        let indent: Int
        /// The column item content starts at; continuation lines indented at
        /// least this far belong to the item.
        let contentIndent: Int
        let symbol: Character
        let number: Int?
        let content: String

        init?(_ line: String) {
            indent = indentation(line)
            let rest = line.drop(while: { $0 == " " })
            let width: Int
            if let first = rest.first, "-*+".contains(first) {
                symbol = first
                number = nil
                width = 1
            } else {
                let digits = rest.prefix(while: \.isNumber)
                guard (1...9).contains(digits.count), let value = Int(digits),
                    let delimiter = rest.dropFirst(digits.count).first, delimiter == "." || delimiter == ")"
                else { return nil }
                symbol = delimiter
                number = value
                width = digits.count + 1
            }
            let afterMarker = rest.dropFirst(width)
            guard afterMarker.isEmpty || afterMarker.first == " " else { return nil }
            let spaces = afterMarker.prefix(while: { $0 == " " }).count
            if afterMarker.count == spaces || spaces > 4 {
                // Empty item, or indented code after the marker: content is one space in.
                contentIndent = indent + width + 1
                content = String(afterMarker.dropFirst(min(spaces, 1)))
            } else {
                contentIndent = indent + width + spaces
                content = String(afterMarker.dropFirst(spaces))
            }
        }

        /// An empty item, or a numbered one not starting at 1, can't break into
        /// a paragraph ("In\n2024. it rained" stays prose).
        var canInterruptParagraph: Bool {
            !content.trimmingCharacters(in: .whitespaces).isEmpty && (number == nil || number == 1)
        }

        /// Same list type as `first` — a different bullet or delimiter starts a new list.
        func continues(_ first: ListMarker) -> Bool {
            symbol == first.symbol && (number == nil) == (first.number == nil)
        }
    }
}

private func isBlank(_ line: String) -> Bool {
    line.allSatisfy { $0 == " " }
}

private func indentation(_ line: String) -> Int {
    line.prefix(while: { $0 == " " }).count
}
