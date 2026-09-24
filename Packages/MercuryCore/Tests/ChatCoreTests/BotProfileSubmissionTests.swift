import MercuryKit
import Testing

@testable import ChatCore

/// The advanced editor locks while a save is pending, and a guarded model's
/// confirmation approves the model that was submitted, not whatever the
/// draft holds by the time the user answers the warning (#98).
@Suite("Bot profile submission")
struct BotProfileSubmissionTests {
    private func draft(model: String) throws -> BotProfileDraft {
        let profile = try #require(ProfileDescription(json: ["name": "scout", "model": [:]]))
        var draft = BotProfileDraft(profile)
        draft.model = .init(provider: "openrouter", model: model)
        return draft
    }

    @Test func anIdleEditorIsUnlocked() {
        let submission = BotProfileSubmission()
        #expect(!submission.isLocked)
        #expect(!submission.isSaving)
    }

    @Test func submittingLocksTheEditorUntilTheSaveLands() throws {
        var submission = BotProfileSubmission()
        let sent = submission.submit(try draft(model: "a"))
        #expect(sent == (try draft(model: "a")))
        #expect(submission.isLocked)
        #expect(submission.isSaving)
        submission.saveFinished(needsConfirmation: false)
        #expect(!submission.isLocked)
        #expect(!submission.isSaving)
    }

    /// A second Save while one is in flight sends nothing.
    @Test func aSecondSubmitWhileLockedIsRefused() throws {
        var submission = BotProfileSubmission()
        _ = submission.submit(try draft(model: "a"))
        #expect(submission.submit(try draft(model: "b")) == nil)
        #expect(submission.submitted == (try draft(model: "a")))
    }

    /// The editor stays locked while the warning is up, and confirming it
    /// approves model A (the one that produced the warning) even if the
    /// on-screen draft moved to B meanwhile.
    @Test func confirmationApprovesTheSubmittedModel() throws {
        var submission = BotProfileSubmission()
        var live = try draft(model: "a")
        _ = submission.submit(live)
        live.model = .init(provider: "openrouter", model: "b")
        submission.saveFinished(needsConfirmation: true)
        #expect(submission.isLocked)
        #expect(!submission.isSaving)
        #expect(submission.confirm() == .init(provider: "openrouter", model: "a"))
        #expect(submission.isLocked)
        #expect(submission.isSaving)
        submission.confirmFinished()
        #expect(!submission.isLocked)
        #expect(!submission.isSaving)
    }

    @Test func confirmingWithNothingAwaitingSendsNothing() throws {
        var idle = BotProfileSubmission()
        #expect(idle.confirm() == nil)
        var inFlight = BotProfileSubmission()
        _ = inFlight.submit(try draft(model: "a"))
        #expect(inFlight.confirm() == nil)
    }

    /// A warning with no submitted model can't be confirmed; the editor
    /// mustn't stay locked behind it.
    @Test func aWarningWithoutAModelUnlocks() throws {
        let profile = try #require(ProfileDescription(json: ["name": "scout", "model": [:]]))
        var unpinned = BotProfileDraft(profile)
        unpinned.soul = "# Scout"
        var submission = BotProfileSubmission()
        _ = submission.submit(unpinned)
        submission.saveFinished(needsConfirmation: true)
        #expect(submission.confirm() == nil)
        #expect(!submission.isLocked)
    }

    @Test func cancellingTheWarningUnlocks() throws {
        var submission = BotProfileSubmission()
        _ = submission.submit(try draft(model: "a"))
        submission.saveFinished(needsConfirmation: true)
        submission.cancelConfirmation()
        #expect(!submission.isLocked)
        #expect(submission.confirm() == nil)
    }
}
