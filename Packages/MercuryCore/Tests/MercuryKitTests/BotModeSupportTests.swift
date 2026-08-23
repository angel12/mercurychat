import Foundation
import Testing

@testable import MercuryKit

@Suite("BotModeSupport verdicts")
struct BotModeSupportTests {
    @Test func methodNotFoundMeansUnsupported() {
        let error = HermesError.rpcError(
            code: HermesError.RPCCode.methodNotFound, message: "unknown method: profiles.list")
        #expect(BotModeSupport.verdict(from: error) == false)
    }

    @Test func otherRPCErrorsAreInconclusive() {
        // A busy or misbehaving gateway that still HAS the method must not be
        // cached as unsupported.
        let error = HermesError.rpcError(
            code: HermesError.RPCCode.sessionBusy, message: "busy")
        #expect(BotModeSupport.verdict(from: error) == nil)
    }

    @Test func transportFailuresAreInconclusive() {
        #expect(BotModeSupport.verdict(from: HermesError.timeout("profiles.list")) == nil)
        #expect(BotModeSupport.verdict(from: HermesError.connectionClosed(nil)) == nil)
        #expect(BotModeSupport.verdict(from: HermesError.notConnected) == nil)
    }

    @Test func foreignErrorsAreInconclusive() {
        #expect(BotModeSupport.verdict(from: URLError(.timedOut)) == nil)
    }
}
