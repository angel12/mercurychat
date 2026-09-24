import Foundation
import MercuryKit

/// The connect screen's server + token fields, with the token bound to the
/// endpoint it belongs to (#104). Without the binding, a token autofilled
/// from A's dashboard URL — or typed for A and submitted — stayed in the
/// field after the user edited the server to B, and the next Connect sent
/// A's token to B.
///
/// A token becomes bound once it is used for a server: autofilled from a
/// pasted dashboard URL, or submitted with a Connect attempt. Changing the
/// server to a different endpoint identity (`ServerEndpoint.key`: scheme,
/// host, port) then clears it. An unbound token — typed before any attempt —
/// is left alone, so typing the server after the token still works.
///
/// Public because the app target calls it.
public struct ConnectFormState: Equatable, Sendable {
    public private(set) var server = ""
    public private(set) var token = ""
    /// True after a server change cleared a bound token, so the form can say
    /// why the field emptied. Entering a token again resets it.
    public private(set) var tokenWasCleared = false
    private var tokenEndpointKey: String?

    public init() {}

    public mutating func setServer(_ newValue: String) {
        server = newValue
        let parsed = try? ServerEndpoint.parse(newValue)
        if let parsed, let embedded = parsed.embeddedToken {
            // Pasting a dashboard URL auto-fills (and binds) its token.
            token = embedded
            tokenEndpointKey = parsed.endpoint.key
            tokenWasCleared = false
        } else if let bound = tokenEndpointKey, bound != parsed?.endpoint.key {
            token = ""
            tokenEndpointKey = nil
            tokenWasCleared = true
        }
    }

    public mutating func setToken(_ newValue: String) {
        token = newValue
        tokenWasCleared = false
        if newValue.isEmpty { tokenEndpointKey = nil }
    }

    /// Call when Connect submits the form: from here on the token belongs to
    /// the server it was sent to.
    public mutating func recordAttempt() {
        guard !token.isEmpty else { return }
        tokenEndpointKey = Self.endpointKey(server)
    }

    /// The token to send with a Connect, or nil. Never a token bound to a
    /// different endpoint than the current server.
    public var connectToken: String? {
        guard !token.isEmpty else { return nil }
        if let bound = tokenEndpointKey, bound != Self.endpointKey(server) { return nil }
        return token
    }

    private static func endpointKey(_ server: String) -> String? {
        (try? ServerEndpoint.parse(server))?.endpoint.key
    }
}
