import Foundation
import Testing

@testable import ChatCore

private struct TestError: Error {}

private func pending(_ name: String, kind: MessageAttachment.Kind = .image) -> PendingAttachment {
    PendingAttachment(filename: name, data: Data([0x01]), kind: kind)
}

/// The common attach result: one staged path, no ref line.
private func staged(_ path: String) -> StagedAttachment {
    StagedAttachment(detachPaths: [path], refText: nil)
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
                return staged("/staged/\(att.filename)")
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
                    return staged("/staged/\(att.filename)")
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
                attach: { att in staged("/staged/\(att.filename)") },
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
                return staged("")
            },
            detach: { _ in Issue.record("detach must not be called") },
            submit: { _ in "queued" })
        #expect(status == "queued")
    }

    @Test func fileRefsAreAppendedToSubmittedText() async throws {
        let log = CallLog()
        _ = try await AttachmentUpload.dispatch(
            text: "look at these",
            attachments: [pending("a.csv", kind: .file), pending("b.txt", kind: .file)],
            attach: { att in
                StagedAttachment(detachPaths: [], refText: "@file:/tmp/att/\(att.filename)")
            },
            detach: { _ in Issue.record("detach must not be called") },
            submit: { text in
                await log.record("submit:\(text)")
                return "queued"
            })
        #expect(
            await log.calls == ["submit:look at these\n@file:/tmp/att/a.csv\n@file:/tmp/att/b.txt"])
    }

    @Test func refsOnlySubmitOmitsLeadingNewline() async throws {
        let log = CallLog()
        _ = try await AttachmentUpload.dispatch(
            text: "",
            attachments: [pending("a.csv", kind: .file)],
            attach: { _ in StagedAttachment(detachPaths: [], refText: "@file:a.csv") },
            detach: { _ in Issue.record("detach must not be called") },
            submit: { text in
                await log.record("submit:\(text)")
                return nil
            })
        #expect(await log.calls == ["submit:@file:a.csv"])
    }

    /// A PDF stages one path per rendered page, and a staged file stages none:
    /// cleanup unstages every page and leaves the inert file alone.
    @Test func failedSubmitDetachesEveryStagedPathIncludingPDFPages() async {
        let log = CallLog()
        await #expect(throws: TestError.self) {
            try await AttachmentUpload.dispatch(
                text: "hi",
                attachments: [pending("doc.pdf", kind: .pdf), pending("x.bin", kind: .file)],
                attach: { att in
                    att.kind == .pdf
                        ? StagedAttachment(detachPaths: ["/p1.png", "/p2.png"], refText: nil)
                        : StagedAttachment(detachPaths: [], refText: "@file:x.bin")
                },
                detach: { path in await log.record("detach:\(path)") },
                submit: { _ in throw TestError() })
        }
        #expect(await log.calls == ["detach:/p1.png", "detach:/p2.png"])
    }
}
