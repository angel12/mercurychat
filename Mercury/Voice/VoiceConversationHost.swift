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

    /// The name the system call UI shows.
    var callDisplayName: String {
        if case .session(_, let title?, _) = target, !title.isEmpty { return title }
        return "Voice conversation"
    }

    static let needsInputStatus = VoiceActivityPhase.needsInput.label

    /// The background bar's status line.
    var barStatus: String {
        Self.activityPhase(
            needsInput: controller.needsInput, waiting: controller.isWaitingForTurn,
            reconnecting: !controller.connectionHealthy, state: controller.voiceState
        ).label
    }

    /// The status line for a healthy connection: the phase's label. The
    /// instance `barStatus` also folds in a dropped gateway ("Reconnecting").
    static func barStatus(needsInput: Bool, waiting: Bool, state: ConversationUIState) -> String {
        activityPhase(needsInput: needsInput, waiting: waiting, reconnecting: false, state: state)
            .label
    }

    /// A prompt waiting on the user outranks everything: from another
    /// screen or the lock screen it is the only sign the conversation is
    /// blocked on them. Then a dropped gateway, a queued turn, a pause, a mute.
    static func activityPhase(
        needsInput: Bool, waiting: Bool, reconnecting: Bool, state: ConversationUIState
    ) -> VoiceActivityPhase {
        if needsInput { return .needsInput }
        if reconnecting { return .reconnecting }
        if waiting { return .waiting }
        if state.paused { return .paused }
        if state.muted { return .muted }
        switch state.status {
        case .idle: return .paused
        case .listening: return .listening
        case .transcribing: return .transcribing
        case .thinking: return .thinking
        case .speaking: return .speaking
        }
    }

    /// The session's live title, else the target's, else "Voice conversation".
    var displayTitle: String {
        if let title = controller.sessionTitle, !title.isEmpty { return title }
        return callDisplayName
    }

    /// What the Live Activity shows (spec §2).
    var activityContent: VoiceActivityContent {
        VoiceActivityContent(
            title: displayTitle,
            phase: Self.activityPhase(
                needsInput: controller.needsInput, waiting: controller.isWaitingForTurn,
                reconnecting: !controller.connectionHealthy, state: controller.voiceState),
            muted: controller.voiceState.muted)
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
