import Foundation
import Testing

@Suite("MarkdownBlocks")
struct MarkdownBlocksTests {
    typealias Block = MarkdownBlocks.Block

    private func item(_ blocks: Block..., checked: Bool? = nil) -> MarkdownList.Item {
        MarkdownList.Item(checked: checked, blocks: blocks)
    }

    // MARK: Paragraphs

    @Test func plainProseIsOneBlock() {
        #expect(MarkdownBlocks.parse("hello **world**") == [.prose("hello **world**")])
    }

    @Test func blankLinesSplitParagraphsAndSoftBreaksSurvive() {
        #expect(
            MarkdownBlocks.parse("one\ntwo\n\n\nthree") == [.prose("one\ntwo"), .prose("three")])
    }

    @Test func crlfLineEndingsAreNormalized() {
        #expect(MarkdownBlocks.parse("# Hi\r\nthere\r\n") == [.heading(level: 1, text: "Hi"), .prose("there")])
    }

    // MARK: Code

    @Test func fencedCodeSplitsOut() {
        let blocks = MarkdownBlocks.parse("before\n```swift\nlet x = 1\n```\nafter")
        #expect(blocks == [.prose("before"), .code("let x = 1", language: "swift"), .prose("after")])
    }

    @Test func unterminatedFenceIsGrowingCode() {
        #expect(MarkdownBlocks.parse("```\nlet") == [.code("let", language: nil)])
    }

    @Test func tildeFenceAndLongerBacktickFenceNestShorterOnes() {
        #expect(MarkdownBlocks.parse("~~~py\nx\n~~~") == [.code("x", language: "py")])
        #expect(
            MarkdownBlocks.parse("````md\n```\ninner\n```\n````")
                == [.code("```\ninner\n```", language: "md")])
    }

    @Test func markdownInsideCodeFenceStaysCode() {
        let blocks = MarkdownBlocks.parse("```\n# not a heading\n| a |\n|---|\n- x\n```")
        #expect(blocks == [.code("# not a heading\n| a |\n|---|\n- x", language: nil)])
    }

    // MARK: Headings and rules

    @Test func atxHeadingsAllLevels() {
        let blocks = MarkdownBlocks.parse("# One\n## Two ##\n###### Six\n####### seven")
        #expect(
            blocks == [
                .heading(level: 1, text: "One"),
                .heading(level: 2, text: "Two"),
                .heading(level: 6, text: "Six"),
                .prose("####### seven"),
            ])
    }

    @Test func hashWithoutSpaceIsNotAHeading() {
        #expect(MarkdownBlocks.parse("#hashtag") == [.prose("#hashtag")])
    }

    @Test func headingInterruptsParagraph() {
        #expect(
            MarkdownBlocks.parse("intro\n## Next\nbody")
                == [.prose("intro"), .heading(level: 2, text: "Next"), .prose("body")])
    }

    @Test func setextHeadings() {
        #expect(
            MarkdownBlocks.parse("Title\n=====\nSub\n---")
                == [.heading(level: 1, text: "Title"), .heading(level: 2, text: "Sub")])
    }

    @Test func thematicBreaks() {
        #expect(
            MarkdownBlocks.parse("a\n\n---\n\n* * *\n___\nb")
                == [.prose("a"), .rule, .rule, .rule, .prose("b")])
    }

    // MARK: Quotes and callouts

    @Test func blockquoteParsesItsContentAsBlocks() {
        #expect(
            MarkdownBlocks.parse("> ## Quoted\n> line one\n>\n> - item")
                == [
                    .quote([
                        .heading(level: 2, text: "Quoted"),
                        .prose("line one"),
                        .list(MarkdownList(start: nil, items: [item(.prose("item"))])),
                    ])
                ])
    }

    @Test func nestedBlockquote() {
        #expect(MarkdownBlocks.parse("> outer\n>> inner") == [.quote([.prose("outer"), .quote([.prose("inner")])])])
    }

    @Test func blankLineEndsQuote() {
        #expect(MarkdownBlocks.parse("> q\n\nafter") == [.quote([.prose("q")]), .prose("after")])
    }

    @Test func lazyContinuationStaysInQuote() {
        #expect(MarkdownBlocks.parse("> quoted\nstill quoted") == [.quote([.prose("quoted\nstill quoted")])])
    }

    @Test func githubCallouts() {
        #expect(
            MarkdownBlocks.parse("> [!WARNING]\n> Danger ahead")
                == [.callout(.warning, [.prose("Danger ahead")])])
        #expect(MarkdownBlocks.parse("> [!tip] Inline body") == [.callout(.tip, [.prose("Inline body")])])
        #expect(MarkdownBlocks.parse("> [!BOGUS]\n> x") == [.quote([.prose("[!BOGUS]\nx")])])
    }

    // MARK: Lists

    @Test func bulletList() {
        #expect(
            MarkdownBlocks.parse("- one\n- **two**\n* star")
                == [
                    .list(MarkdownList(start: nil, items: [item(.prose("one")), item(.prose("**two**"))])),
                    .list(MarkdownList(start: nil, items: [item(.prose("star"))])),
                ])
    }

    @Test func orderedListKeepsStartNumber() {
        #expect(
            MarkdownBlocks.parse("3. three\n4. four")
                == [.list(MarkdownList(start: 3, items: [item(.prose("three")), item(.prose("four"))]))])
    }

    @Test func nestedListsByIndentation() {
        let text = """
            1. First
               - sub a
               - sub b
            2. Second
              - two-space sub
            """
        #expect(
            MarkdownBlocks.parse(text) == [
                .list(
                    MarkdownList(
                        start: 1,
                        items: [
                            item(
                                .prose("First"),
                                .list(
                                    MarkdownList(
                                        start: nil, items: [item(.prose("sub a")), item(.prose("sub b"))]))),
                            item(
                                .prose("Second"),
                                .list(MarkdownList(start: nil, items: [item(.prose("two-space sub"))]))),
                        ]))
            ])
    }

    @Test func looseListItemsAndContinuationParagraphs() {
        let text = "- one\n\n  more of one\n\n- two\n\nafter"
        #expect(
            MarkdownBlocks.parse(text) == [
                .list(
                    MarkdownList(
                        start: nil,
                        items: [item(.prose("one"), .prose("more of one")), item(.prose("two"))])),
                .prose("after"),
            ])
    }

    @Test func codeFenceInsideListItem() {
        #expect(
            MarkdownBlocks.parse("- run:\n  ```sh\n  make\n  ```")
                == [.list(MarkdownList(start: nil, items: [item(.prose("run:"), .code("make", language: "sh"))]))])
    }

    @Test func taskList() {
        #expect(
            MarkdownBlocks.parse("- [ ] todo\n- [x] done\n- [X] Done")
                == [
                    .list(
                        MarkdownList(
                            start: nil,
                            items: [
                                item(.prose("todo"), checked: false),
                                item(.prose("done"), checked: true),
                                item(.prose("Done"), checked: true),
                            ]))
                ])
    }

    @Test func listInterruptsParagraphOnlyWithContentOrOne() {
        #expect(
            MarkdownBlocks.parse("Steps:\n1. go")
                == [.prose("Steps:"), .list(MarkdownList(start: 1, items: [item(.prose("go"))]))])
        #expect(MarkdownBlocks.parse("In\n2024. it rained") == [.prose("In\n2024. it rained")])
    }

    @Test func dashesThatAreNotMarkers() {
        #expect(MarkdownBlocks.parse("-5 degrees") == [.prose("-5 degrees")])
        #expect(MarkdownBlocks.parse("**bold** start") == [.prose("**bold** start")])
    }

    // MARK: Images and math

    @Test func standaloneRemoteImageIsImageBlock() {
        #expect(
            MarkdownBlocks.parse("![a cat](https://example.com/cat.png \"title\")")
                == [.image(alt: "a cat", url: URL(string: "https://example.com/cat.png")!)])
    }

    @Test func inlineOrLocalImageStaysProse() {
        #expect(MarkdownBlocks.parse("see ![x](https://e.com/x.png) here") == [.prose("see ![x](https://e.com/x.png) here")])
        #expect(MarkdownBlocks.parse("![x](/tmp/x.png)") == [.prose("![x](/tmp/x.png)")])
    }

    @Test func displayMathBlocks() {
        #expect(MarkdownBlocks.parse("$$\nE = mc^2\n$$") == [.math("E = mc^2")])
        #expect(MarkdownBlocks.parse("$$a+b$$") == [.math("a+b")])
        #expect(MarkdownBlocks.parse("\\[\nx^2\n\\]") == [.math("x^2")])
        #expect(MarkdownBlocks.parse("$$\nx +") == [.math("x +")])
    }

    // MARK: Tables

    @Test func tableBecomesTableBlock() {
        let text = """
            Here you go:

            | Name | Qty |
            |------|----:|
            | **apple** | 3 |
            | pear | 10 |

            Done.
            """
        #expect(
            MarkdownBlocks.parse(text) == [
                .prose("Here you go:"),
                .table(
                    MarkdownTable(
                        header: ["Name", "Qty"],
                        alignments: [.leading, .trailing],
                        rows: [["**apple**", "3"], ["pear", "10"]])),
                .prose("Done."),
            ])
    }

    @Test func tableInterruptsParagraph() {
        let blocks = MarkdownBlocks.parse("Here:\n| a |\n|---|\n| 1 |")
        #expect(blocks == [.prose("Here:"), .table(MarkdownTable(header: ["a"], alignments: [.leading], rows: [["1"]]))])
    }

    @Test func tableWithoutOuterPipesAndCenterAlignment() {
        #expect(
            MarkdownBlocks.parse("a | b\n:-:|---\n1 | 2") == [
                .table(MarkdownTable(header: ["a", "b"], alignments: [.center, .leading], rows: [["1", "2"]]))
            ])
    }

    @Test func raggedRowsArePaddedAndTrimmedToHeaderWidth() {
        let blocks = MarkdownBlocks.parse("| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |")
        guard case .table(let table) = blocks.first else {
            Issue.record("expected table, got \(blocks)")
            return
        }
        #expect(table.rows == [["1", ""], ["1", "2"]])
    }

    @Test func escapedPipeStaysInCell() {
        let blocks = MarkdownBlocks.parse("| a |\n|---|\n| x \\| y |")
        guard case .table(let table) = blocks.first else {
            Issue.record("expected table, got \(blocks)")
            return
        }
        #expect(table.rows == [["x | y"]])
    }

    @Test func headerWithoutDelimiterRowStaysProse() {
        // Mid-stream: the delimiter row hasn't arrived yet.
        #expect(MarkdownBlocks.parse("| a | b |\n") == [.prose("| a | b |")])
    }

    @Test func pipeInsideProseIsNotATable() {
        #expect(MarkdownBlocks.parse("use a | b here\nnext line") == [.prose("use a | b here\nnext line")])
    }

    @Test func mismatchedDelimiterColumnCountIsNotATable() {
        let text = "| a | b |\n|---|\n| 1 | 2 |"
        #expect(MarkdownBlocks.parse(text) == [.prose(text)])
    }

    // MARK: Inline

    @Test func brTagsBecomeLineBreaks() {
        #expect(MarkdownBlocks.normalizeInline("a<br>b<br/>c<BR />d") == "a\nb\nc\nd")
    }
}
