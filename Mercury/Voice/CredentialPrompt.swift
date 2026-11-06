import Foundation
import MercuryKit

/// A sudo password or a secret the agent is waiting on, arriving as a server
/// request (`sudo` / `secret`). Unlike the retired "unanswerable" prompt, the
/// voice conversation collects the value on screen and answers it, as Chat
/// does. Nothing the user types is ever spoken or logged.
enum CredentialPrompt: Equatable, Identifiable, Sendable {
    case sudo(SudoRequest)
    case secret(SecretRequest)

    init?(serverRequest request: ServerRequest) {
        if let sudo = SudoRequest(serverRequest: request) { self = .sudo(sudo) }
        else if let secret = SecretRequest(serverRequest: request) { self = .secret(secret) }
        else { return nil }
    }

    /// The server request id (`request.answer` / `request.cancel` key).
    var id: String {
        switch self {
        case .sudo(let r): r.serverRequestID ?? r.requestID
        case .secret(let r): r.serverRequestID ?? r.requestID
        }
    }

    /// Spoken on arrival. Fixed text: the request's own text is shown, never
    /// spoken, and nothing the user types is ever spoken or logged.
    var spokenNotice: String {
        switch self {
        case .sudo: "Hermes needs your sudo password. It's on screen."
        case .secret: "Hermes needs a secret. It's on screen."
        }
    }
}

/// Outcome of one credential submit/decline, from a sheet's point of view.
enum CredentialSubmitOutcome: Equatable, Sendable {
    /// Delivered (or already expired) and nothing else is waiting: close.
    case done
    /// Delivered, but another prompt of the same kind is now showing: keep
    /// the sheet open (Chat's queued-sudo behaviour).
    case stay
    /// Not delivered; the message is shown on the sheet for a retry.
    case failed(String)
}
