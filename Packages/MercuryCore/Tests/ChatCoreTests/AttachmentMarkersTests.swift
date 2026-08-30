import Foundation
import Testing
import MercuryKit

@testable import ChatCore

private func json(_ text: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Suite("AttachmentMarkers")
struct AttachmentMarkersTests {
    @Test func stripsTrailingImageRefsIntoAttachments() {
        let text = "what is this?\n@image:/tmp/photo.jpg"
        let parsed = AttachmentMarkers.parse(text: text, rawContent: nil)
        #expect(parsed.text == "what is this?")
        #expect(parsed.attachments.count == 1)
        #expect(parsed.attachments.first?.filename == "photo.jpg")
        #expect(parsed.attachments.first?.kind == .image)
        #expect(parsed.attachments.first?.previewData == nil)
    }

    @Test func unquotesQuotedRefPaths() {
        let text = "look\n@image:`/tmp/with space/shot 2.png`\n@image:\"/tmp/b.jpg\""
        let parsed = AttachmentMarkers.parse(text: text, rawContent: nil)
        #expect(parsed.text == "look")
        #expect(parsed.attachments.map(\.filename) == ["shot 2.png", "b.jpg"])
    }

    @Test func imageOnlyRefRowHasEmptyTextButAnAttachment() {
        let parsed = AttachmentMarkers.parse(
            text: "@image:/tmp/shot.png", rawContent: nil)
        #expect(parsed.text.isEmpty)
        #expect(parsed.attachments.count == 1)
        #expect(parsed.attachments.first?.filename == "shot.png")
    }

    @Test func plainTextPassesThroughUntouched() {
        let parsed = AttachmentMarkers.parse(
            text: "email me @image:stuff later\nok?", rawContent: nil)
        #expect(parsed.text == "email me @image:stuff later\nok?")
        #expect(parsed.attachments.isEmpty)
    }

    @Test func onlyTheTrailingRunIsStripped() {
        // A ref-shaped line the user typed mid-message is their own text —
        // persistence only ever APPENDS refs.
        let text = "@image:/tmp/a.png\nis how you reference images, right?"
        let parsed = AttachmentMarkers.parse(text: text, rawContent: nil)
        #expect(parsed.text == text)
        #expect(parsed.attachments.isEmpty)
    }

    @Test func structuredContentParsesRefsFromTextPart() {
        // Native-vision persistence: text part carries the same trailing
        // refs; image_url parts must NOT double-count.
        let content = json(
            #"[{"type": "text", "text": "check this\n@image:/tmp/pic.png"}, {"type": "image_url", "image_url": {"url": "data:image/png;base64,xx"}}]"#
        )
        let parsed = AttachmentMarkers.parse(text: "", rawContent: content)
        #expect(parsed.text == "check this")
        #expect(parsed.attachments.count == 1)
        #expect(parsed.attachments.first?.filename == "pic.png")
    }

    @Test func stripsFlattenedNativeVisionProjection() {
        // REST projection of a structured row: caption, ref line, then a
        // literal [screenshot] line per image part.
        let text = "what is this?\n@image:/tmp/upload_1.jpg\n[screenshot]"
        let parsed = AttachmentMarkers.parse(text: text, rawContent: nil)
        #expect(parsed.text == "what is this?")
        #expect(parsed.attachments.map(\.filename) == ["upload_1.jpg"])
    }

    @Test func imageOnlyFlattenedProjectionParses() {
        let parsed = AttachmentMarkers.parse(
            text: "@image:/tmp/upload_2.jpg\n[screenshot]", rawContent: nil)
        #expect(parsed.text.isEmpty)
        #expect(parsed.attachments.count == 1)
    }

    @Test func bareScreenshotLineWithoutRefsIsUntouched() {
        let parsed = AttachmentMarkers.parse(text: "done\n[screenshot]", rawContent: nil)
        #expect(parsed.text == "done\n[screenshot]")
        #expect(parsed.attachments.isEmpty)
    }

    // MARK: - `@file:` refs and expansion blocks

    @Test func stripsTrailingFileRefs() {
        let parsed = AttachmentMarkers.parse(
            text: "please review\n@file:/home/h/attachments/notes.txt\n@file:`/home/h/attachments/two words.csv`",
            rawContent: nil)
        #expect(parsed.text == "please review")
        #expect(parsed.attachments.map(\.filename) == ["notes.txt", "two words.csv"])
        #expect(parsed.attachments.allSatisfy { $0.kind == .file })
    }

    @Test func stripsContextWarningsBlockAfterFileRefs() {
        // The realistic `file.attach` shape (probed against the live backend):
        // the staged path lives outside the session cwd, so expansion REFUSES
        // it and the row carries a warnings block instead of inlined content.
        let text = """
            caption line
            @file:/Users/h/.hermes/attachments/probe.txt

            --- Context Warnings ---
            - @file:/Users/h/.hermes/attachments/probe.txt: path is outside the allowed workspace
            """
        let parsed = AttachmentMarkers.parse(text: text, rawContent: nil)
        #expect(parsed.text == "caption line")
        #expect(parsed.attachments.map(\.filename) == ["probe.txt"])
        #expect(parsed.attachments.map(\.kind) == [.file])
    }

    @Test func refsOnlyWarningsRowParsesToEmptyText() {
        let text = """
            @file:/Users/h/.hermes/attachments/probe.bin

            --- Context Warnings ---
            - @file:/Users/h/.hermes/attachments/probe.bin: path is outside the allowed workspace
            """
        let parsed = AttachmentMarkers.parse(text: text, rawContent: nil)
        #expect(parsed.text.isEmpty)
        #expect(parsed.attachments.map(\.filename) == ["probe.bin"])
    }

    @Test func stripsAttachedContextBlockAfterFileRefs() {
        // Reachable when the user hand-types an IN-WORKSPACE `@file:` ref:
        // expansion is allowed, so the row carries the verbatim inline block
        // (📄 header + fence for text, 📎 one-liner for binary).
        let text = """
            caption two
            @file:inws.txt
            @file:inws.bin

            --- Attached Context ---

            📄 @file:inws.txt (8 tokens)
            ```
            workspace alpha
            workspace beta
            ```

            📎 @file:inws.bin (application/octet-stream, 70 B) — binary file, not inlined as text. It is available on disk at `/tmp/probe_ws/inws.bin`. Use your tools to work with it (read or convert it, extract its text, or view/render it as needed); do not tell the user the file type is unsupported.
            """
        let parsed = AttachmentMarkers.parse(text: text, rawContent: nil)
        #expect(parsed.text == "caption two")
        #expect(parsed.attachments.map(\.filename) == ["inws.txt", "inws.bin"])
        #expect(parsed.attachments.allSatisfy { $0.kind == .file })
    }

    @Test func stripsWarningsAndContextBlocks() {
        let text = """
            look
            @file:/home/h/attachments/probe.bin

            --- Context Warnings ---
            - @file:/home/h/attachments/probe.bin: path is outside the allowed workspace

            --- Attached Context ---

            📎 stuff
            """
        let parsed = AttachmentMarkers.parse(text: text, rawContent: nil)
        #expect(parsed.text == "look")
        #expect(parsed.attachments.count == 1)
    }

    @Test func imageRefsAfterExpansionBlocksStillParse() {
        // Files + images in one send: the server appends `@image:` refs AFTER
        // the (already expanded) prompt, i.e. after the block.
        let text = """
            both
            @file:/home/h/attachments/a.txt

            --- Attached Context ---

            block
            @image:/img/shot.png
            """
        let parsed = AttachmentMarkers.parse(text: text, rawContent: nil)
        #expect(parsed.text == "both")
        #expect(parsed.attachments.map(\.filename) == ["a.txt", "shot.png"])
        #expect(parsed.attachments.map(\.kind) == [.file, .image])
    }

    @Test func refsOnlyFileMessageParsesToEmptyText() {
        let parsed = AttachmentMarkers.parse(
            text: "@file:/home/h/attachments/a.txt", rawContent: nil)
        #expect(parsed.text == "")
        #expect(parsed.attachments.count == 1)
        #expect(parsed.attachments.first?.kind == .file)
    }

    @Test func hydratedRefsAreIndexedInDocumentOrder() {
        let text = """
            mixed
            @file:/a/one.txt

            --- Context Warnings ---
            - @file:/a/one.txt: path is outside the allowed workspace
            @image:/i/two.png
            [screenshot]
            """
        let parsed = AttachmentMarkers.parse(text: text, rawContent: nil)
        #expect(parsed.text == "mixed")
        #expect(parsed.attachments.map(\.id) == ["hydrated-0", "hydrated-1"])
        #expect(parsed.attachments.map(\.filename) == ["one.txt", "two.png"])
        #expect(parsed.attachments.map(\.kind) == [.file, .image])
    }

    @Test func pdfSendHydratesAsOnePageChipPerRenderedPage() {
        // `pdf.attach` drains into the next submit as the images-v1
        // projection: one `@image:` line per page, then one `[screenshot]`.
        let text = """
            what did I attach?
            @image:/Users/h/.hermes/images/pdf_p1_20260829_201518_1.png
            @image:/Users/h/.hermes/images/pdf_p2_20260829_201518_2.png
            [screenshot]
            [screenshot]
            """
        let parsed = AttachmentMarkers.parse(text: text, rawContent: nil)
        #expect(parsed.text == "what did I attach?")
        #expect(
            parsed.attachments.map(\.filename) == [
                "pdf_p1_20260829_201518_1.png", "pdf_p2_20260829_201518_2.png",
            ])
        #expect(parsed.attachments.allSatisfy { $0.kind == .image })
    }

    @Test func plainTextContainingMarkerLineWithoutRefsIsUntouched() {
        // Stripping expansion blocks is gated on a ref run existing — a user
        // who typed the marker line with no attachments keeps their text.
        let text = "I typed\n--- Attached Context ---\nby hand"
        let parsed = AttachmentMarkers.parse(text: text, rawContent: nil)
        #expect(parsed.text == text)
        #expect(parsed.attachments.isEmpty)
    }

    @Test func plainTextContainingWarningsMarkerWithoutRefsIsUntouched() {
        let text = "--- Context Warnings ---\nis a line I like to type"
        let parsed = AttachmentMarkers.parse(text: text, rawContent: nil)
        #expect(parsed.text == text)
        #expect(parsed.attachments.isEmpty)
    }

    @Test func midMessageFileRefLineIsLeftAlone() {
        let text = "@file:/x/y.txt is my favorite path\nthanks"
        let parsed = AttachmentMarkers.parse(text: text, rawContent: nil)
        #expect(parsed.text == text)
        #expect(parsed.attachments.isEmpty)
    }

    @Test func structuredContentWithoutRefsFallsBackToImageParts() {
        let content = json(
            #"[{"type": "text", "text": "check this"}, {"type": "image_url", "image_url": {"url": "data:image/png;base64,xx"}}]"#
        )
        let parsed = AttachmentMarkers.parse(text: "", rawContent: content)
        #expect(parsed.text == "check this")
        #expect(parsed.attachments.count == 1)
        #expect(parsed.attachments.first?.filename == "Image")
    }
}
