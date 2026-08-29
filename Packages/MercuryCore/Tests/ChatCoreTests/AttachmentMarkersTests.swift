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
