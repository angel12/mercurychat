import Foundation
import MercuryKit
import MercuryVoiceEngine
import Observation

/// The app's single voice conversation (Voice tab). Owned by `AppModel`;
/// every window's conversation screen and "In voice conversation" bar bind
/// to it. It outlives navigation: only an explicit end releases it.
@MainActor @Observable
final class VoiceConversationHost {
    enum Target: Hashable {
        case session(storedID: String, title: String?, profile: String?)
        case new(cwd: String?, profile: String?, request: UUID)

        var mode: ConversationController.Mode {
            switch self {
            case .session(let storedID, _, _): .resume(storedID: storedID)
            case .new(let cwd, _, _): .create(cwd: cwd, title: nil)
            }
        }

        var profile: String? {
            switch self {
            case .session(_, _, let profile), .new(_, let profile, _): profile
            }
        }
    }

    let target: Target
    let controller: ConversationController
    /// The profile the conversation runs in: the target's, or the profile
    /// selected when it started.
    let profile: String?

    init(target: Target, controller: ConversationController, profile: String?) {
        self.target = target
        self.controller = controller
        self.profile = profile
    }

    static let needsInputStatus = "Needs your input"

    /// The background bar's status line.
    var barStatus: String {
        Self.barStatus(
            needsInput: controller.needsInput, waiting: controller.isWaitingForTurn,
            state: controller.voiceState)
    }

    /// A prompt waiting on the user outranks everything: from another
    /// screen it is the only sign the conversation is blocked on them.
    static func barStatus(needsInput: Bool, waiting: Bool, state: ConversationUIState) -> String {
        if needsInput { return needsInputStatus }
        if waiting { return "Waiting" }
        if state.paused { return "Paused" }
        if state.muted { return "Muted" }
        switch state.status {
        case .idle: return "Paused"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        }
    }

    /// Whether `target` is this conversation: the same target, or the row
    /// of the stored session it holds (a new conversation's session shows up
    /// in the sidebar). A row with no profile of its own matches whatever
    /// profile this one runs in. Clicking it shows the conversation instead
    /// of restarting it.
    func shows(_ target: Target) -> Bool {
        if target == self.target { return true }
        guard case .session(let storedID, _, let rowProfile) = target,
            rowProfile == nil || rowProfile == profile
        else { return false }
        return controller.sessionClaims.contains(.stored(storedID))
    }
}
