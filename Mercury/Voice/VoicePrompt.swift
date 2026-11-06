import Foundation

/// The prompt a voice conversation is waiting on, as notifications see it:
/// a stable key, its kind, and fixed copy. Never carries request content.
struct VoicePrompt: Equatable, Sendable {
    enum Kind: String, Sendable { case approval, clarify, sudo, secret }

    let key: String
    let kind: Kind
    /// The approval's gateway `request_id`, matched against Mercury Push
    /// payloads to remove a duplicate pushed approval. nil for other kinds.
    let pushRequestID: String?

    var body: String {
        switch kind {
        case .approval: "Hermes needs your approval."
        case .clarify: "Hermes has a question for you."
        case .sudo: "Hermes needs your sudo password."
        case .secret: "Hermes needs a secret."
        }
    }
}
