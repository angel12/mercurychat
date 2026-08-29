import Foundation

/// Sequences a send with attachments: stage every attachment, then submit.
///
/// Failure atomicity is the whole point: an image staged by a successful
/// attach whose submit then fails stays staged server-side and would be
/// silently consumed by the NEXT prompt (and double-attached by a retry).
/// Every failure path best-effort detaches what this call staged, then
/// rethrows the original error — so callers may always retry by re-running
/// the full dispatch.
public enum AttachmentUpload {
    public static func dispatch(
        text: String,
        attachments: [PendingAttachment],
        attach: (PendingAttachment) async throws -> String,
        detach: (String) async -> Void,
        submit: (String) async throws -> String?
    ) async throws -> String? {
        var staged: [String] = []
        do {
            for attachment in attachments {
                staged.append(try await attach(attachment))
            }
            return try await submit(text)
        } catch {
            for path in staged { await detach(path) }
            throw error
        }
    }
}
