import Foundation

/// Gateway support for Bot Mode (the desktop `hermes-bots` surface).
///
/// Bot Mode is built on the `profiles.*` WS RPC family, which landed after
/// desktop contract 6 — so its presence cannot be inferred from the contract
/// number alone. The reliable signal is the RPC door itself: `profiles.list`
/// answers on a supporting gateway and returns JSON-RPC -32601 (method not
/// found) on an older one.
public enum BotModeSupport {
    /// Maps a `profiles.list` probe failure to a support verdict.
    ///
    /// - `false`: the gateway answered "unknown method" — definitively
    ///   unsupported until the backend is updated.
    /// - `nil`: transport-shaped failure (timeout, dropped socket, other RPC
    ///   error). Unknown — don't cache a verdict; re-probe next connection.
    public static func verdict(from error: Error) -> Bool? {
        if case HermesError.rpcError(HermesError.RPCCode.methodNotFound, _) = error {
            return false
        }
        return nil
    }
}

extension HermesConnection {
    /// Probe whether this gateway speaks the `profiles.*` RPC family.
    ///
    /// Uses `profiles.list` with `include_sessions: false` — the cheap form
    /// that skips the per-profile state.db walks (last-session previews,
    /// canonical-chat resolution), so the probe stays fast even on gateways
    /// with many profiles.
    public func probeBotModeSupport(timeout: TimeInterval = 20) async -> Bool? {
        do {
            _ = try await request(
                "profiles.list",
                params: .object(["include_sessions": .bool(false)]),
                timeout: timeout)
            return true
        } catch {
            return BotModeSupport.verdict(from: error)
        }
    }
}
