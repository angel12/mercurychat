import Foundation
import Testing

@testable import ChatCore

private struct TestError: Error {}

private func pending(_ name: String) -> PendingAttachment {
    PendingAttachment(filename: name, data: Data([0x01]))
}

/// Order-preserving call recorder for the injected closures.
private actor CallLog {
    var calls: [String] = []
    func record(_ call: String) { calls.append(call) }
}

@Suite("AttachmentUpload")
struct AttachmentUploadTests {
    @Test func attachesEverythingBeforeSubmitting() async throws {
        let log = CallLog()
        let status = try await AttachmentUpload.dispatch(
            text: "hi",
            attachments: [pending("a.jpg"), pending("b.jpg")],
            attach: { att in
                await log.record("attach:\(att.filename)")
                return "/staged/\(att.filename)"
            },
            detach: { path in await log.record("detach:\(path)") },
            submit: { text in
                await log.record("submit:\(text)")
                return "streaming"
            })
        #expect(status == "streaming")
        #expect(await log.calls == ["attach:a.jpg", "attach:b.jpg", "submit:hi"])
    }

    @Test func midBatchAttachFailureDetachesPriorsAndRethrows() async {
        let log = CallLog()
        await #expect(throws: TestError.self) {
            try await AttachmentUpload.dispatch(
                text: "hi",
                attachments: [pending("a.jpg"), pending("b.jpg")],
                attach: { att in
                    if att.filename == "b.jpg" { throw TestError() }
                    await log.record("attach:\(att.filename)")
                    return "/staged/\(att.filename)"
                },
                detach: { path in await log.record("detach:\(path)") },
                submit: { _ in
                    await log.record("submit")
                    return nil
                })
        }
        #expect(await log.calls == ["attach:a.jpg", "detach:/staged/a.jpg"])
    }

    @Test func submitFailureDetachesEverythingStaged() async {
        let log = CallLog()
        await #expect(throws: TestError.self) {
            try await AttachmentUpload.dispatch(
                text: "hi",
                attachments: [pending("a.jpg")],
                attach: { att in "/staged/\(att.filename)" },
                detach: { path in await log.record("detach:\(path)") },
                submit: { _ in throw TestError() })
        }
        #expect(await log.calls == ["detach:/staged/a.jpg"])
    }

    @Test func noAttachmentsIsAPlainSubmit() async throws {
        let status = try await AttachmentUpload.dispatch(
            text: "hi", attachments: [],
            attach: { _ in
                Issue.record("attach must not be called")
                return ""
            },
            detach: { _ in Issue.record("detach must not be called") },
            submit: { _ in "queued" })
        #expect(status == "queued")
    }
}
