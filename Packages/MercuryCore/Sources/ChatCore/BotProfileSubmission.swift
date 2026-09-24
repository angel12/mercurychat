import MercuryKit

/// The advanced bot editor's pending save (#98). While a draft is submitted,
/// whether its request is in flight or its guarded model is waiting on the
/// user's confirmation, the editor is locked: an edit made then would change
/// the on-screen draft but not the submitted copy, and the success dismiss
/// would silently drop it. Keeping the submitted draft here is also what
/// lets the confirmation approve the model the warning was about.
public struct BotProfileSubmission: Equatable, Sendable {
    /// The draft sent by the pending save; nil when nothing is pending.
    public private(set) var submitted: BotProfileDraft?
    /// A request (the save or its confirmation) is awaiting the gateway.
    public private(set) var isSaving = false

    public init() {}

    /// The form, Reload and Back are disabled while this holds.
    public var isLocked: Bool { submitted != nil }

    /// Starts a save of `draft` and returns it to send, or nil (sending
    /// nothing) when a save is already pending.
    public mutating func submit(_ draft: BotProfileDraft) -> BotProfileDraft? {
        guard submitted == nil else { return nil }
        submitted = draft
        isSaving = true
        return draft
    }

    /// The save's reply landed. A guarded model keeps the submitted draft,
    /// and the lock, until the warning is answered.
    public mutating func saveFinished(needsConfirmation: Bool) {
        isSaving = false
        if !needsConfirmation { submitted = nil }
    }

    /// Starts confirming the submitted draft's model and returns it, or nil
    /// when no warning is awaiting an answer. A submitted draft with no
    /// model has nothing to confirm, so it unlocks rather than stick.
    public mutating func confirm() -> ProfileDescription.ModelPin? {
        guard !isSaving else { return nil }
        guard let pin = submitted?.model else {
            submitted = nil
            return nil
        }
        isSaving = true
        return pin
    }

    /// The confirmation's reply landed, either way; a failure is retried
    /// with a fresh Save.
    public mutating func confirmFinished() {
        isSaving = false
        submitted = nil
    }

    /// The user declined the warning.
    public mutating func cancelConfirmation() {
        guard !isSaving else { return }
        submitted = nil
    }
}
