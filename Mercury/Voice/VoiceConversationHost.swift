import Foundation
import MercuryKit
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
    /// `AppModel.voiceGeneration` when this host was made; a begin that
    /// finishes after the generation moved on tears itself down.
    let generation: Int

    init(target: Target, controller: ConversationController, generation: Int) {
        self.target = target
        self.controller = controller
        self.generation = generation
    }
}
