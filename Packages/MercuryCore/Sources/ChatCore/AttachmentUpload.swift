import Foundation

/// What one attach step staged: gateway paths that must be unstaged on any
/// later failure (images and rendered PDF pages sit in `attached_images`
/// and would be silently consumed by the NEXT prompt), and an optional
/// `@file:` directive line for the submitted text (a staged FILE is inert
/// until a prompt references it, so its failure cleanup is simply not
/// submitting the ref).
public struct StagedAttachment: Sendable, Equatable {
    public var detachPaths: [String]
    public var refText: String?

    public init(detachPaths: [String], refText: String?) {
        self.detachPaths = detachPaths
        self.refText = refText
    }
}

/// Sequences a send with attachments: stage every attachment, then submit
/// the text with each staged attachment's `@file:` ref line appended.
///
/// Failure atomicity is the whole point: an image staged by a successful
/// attach whose submit then fails stays staged server-side and would be
/// silently consumed by the NEXT prompt (and double-attached by a retry).
/// Every failure path best-effort detaches the paths this call staged, then
/// rethrows the original error — so callers may always retry by re-running
/// the full dispatch. Staged files need no such unstaging: nothing reads
/// them until a prompt names them, and the failed prompt never shipped.
public enum AttachmentUpload {
    public static func dispatch(
        text: String,
        attachments: [PendingAttachment],
        attach: (PendingAttachment) async throws -> StagedAttachment,
        detach: (String) async -> Void,
        submit: (String) async throws -> String?
    ) async throws -> String? {
        var staged: [StagedAttachment] = []
        do {
            for attachment in attachments {
                staged.append(try await attach(attachment))
            }
            let refs = staged.compactMap(\.refText)
            let outgoing =
                refs.isEmpty
                ? text
                : (text.isEmpty
                    ? refs.joined(separator: "\n")
                    : text + "\n" + refs.joined(separator: "\n"))
            return try await submit(outgoing)
        } catch {
            for path in staged.flatMap(\.detachPaths) { await detach(path) }
            throw error
        }
    }
}
