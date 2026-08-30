import ChatCore
import Foundation
import Testing

@Suite("Chat echo attachments")
struct ChatEchoAttachmentTests {
    @Test func imageEchoCarriesThumbnailBytes() {
        let thumb = Data("thumb".utf8)
        let attachment = PendingAttachment(
            id: "a1", filename: "shot.png", data: Data("full".utf8), kind: .image,
            thumbnail: thumb)
        let echo = ChatController.echoAttachment(for: attachment)
        #expect(echo.id == "a1")
        #expect(echo.kind == .image)
        #expect(echo.filename == "shot.png")
        #expect(echo.previewData == thumb)
    }

    @Test func imageEchoFallsBackToFullBytesWithoutThumbnail() {
        let full = Data("full".utf8)
        let attachment = PendingAttachment(
            id: "a2", filename: "shot.png", data: full, kind: .image, thumbnail: nil)
        #expect(ChatController.echoAttachment(for: attachment).previewData == full)
    }

    /// Non-images render as chips, so the echo must carry no bytes: preview
    /// data would send the row down the thumbnail branch and draw a broken
    /// image instead of the filename chip.
    @Test func fileEchoCarriesNoPreviewBytes() {
        let attachment = PendingAttachment(
            id: "a3", filename: "notes.txt", data: Data("text file bytes".utf8), kind: .file)
        let echo = ChatController.echoAttachment(for: attachment)
        #expect(echo.previewData == nil)
        #expect(echo.filename == "notes.txt")
        #expect(echo.kind == .file)
    }

    @Test func pdfEchoCarriesNoPreviewBytes() {
        let attachment = PendingAttachment(
            id: "a4", filename: "spec.pdf", data: Data("%PDF-1.7".utf8), kind: .pdf,
            thumbnail: Data("thumb".utf8))
        let echo = ChatController.echoAttachment(for: attachment)
        #expect(echo.previewData == nil)
        #expect(echo.filename == "spec.pdf")
        #expect(echo.kind == .pdf)
    }
}
