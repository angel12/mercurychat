import Foundation
import MercuryKit
import Testing

/// Issue #50: `connect()` suspends three times — the status probe, the token
/// validation, and the WS dial — and republishes model state after each. A
/// `disconnect()`, or a second saved-server tap, can land in any of those
/// windows, so every resumption point re-checks `connectGeneration` before
/// publishing anything.
///
/// Those guards had no coverage at all: deleting one changed nothing any
/// suite noticed, while in the app it lets an abandoned connect overwrite the
/// live one — publishing a dead server's status, or installing its connection
/// over the connection the user is actually using.
@Suite("AppModel connect generation", .timeLimit(.minutes(1)))
@MainActor
struct AppModelConnectGenerationTests {
    /// A disconnect while the status probe is still in flight. The probe's
    /// answer belongs to a connect the user has already abandoned, so none of
    /// it may reach the model.
    @Test func disconnectDuringTheProbePublishesNothing() async throws {
        let probed = TestLatch()
        let server = try await HermesTestServer.start { request in
            guard request.path == "/api/status" else { return TestHTTPResponse(200) }
            probed.signal()
            // Hold the probe open so the disconnect below lands while
            // connect() is still suspended on it.
            Thread.sleep(forTimeInterval: 2)
            return TestHTTPResponse(
                200, #"{"auth_required": false, "version": "abandoned"}"#)
        }
        defer { server.stop() }

        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        defer { store.deleteToken(for: endpoint) }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        let connecting = Task { await model.connect(endpoint: endpoint, credentials: nil) }

        #expect(await probed.wait(), "the status probe never reached the server")
        model.disconnect()
        await connecting.value

        #expect(model.serverStatus == nil)
        #expect(model.connection == nil)
        #expect(model.phase == .stopped)
    }

    /// The same race one suspension later: the status probe has already
    /// landed, and the disconnect arrives while the token validation is in
    /// flight. This is the guard that stands between an abandoned connect and
    /// installing its connection — and its update pump — over the live one.
    @Test func disconnectDuringTokenValidationInstallsNoConnection() async throws {
        let validating = TestLatch()
        let server = try await HermesTestServer.start { request in
            switch request.path {
            case "/api/status":
                return TestHTTPResponse(200, #"{"auth_required": false}"#)
            case "/api/profiles/active":
                validating.signal()
                Thread.sleep(forTimeInterval: 2)
                return TestHTTPResponse(200, "{}")
            default:
                return TestHTTPResponse(200)
            }
        }
        defer { server.stop() }

        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        defer { store.deleteToken(for: endpoint) }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        let connecting = Task { await model.connect(endpoint: endpoint, credentials: nil) }

        #expect(await validating.wait(), "token validation never reached the server")
        model.disconnect()
        await connecting.value

        #expect(model.connection == nil)
        #expect(model.phase == .stopped)
    }

    /// A probe that fails *after* the user walked away must not repaint the
    /// connect screen with an error for a server they are no longer trying.
    @Test func aFailedProbeAfterDisconnectShowsNoError() async throws {
        let probed = TestLatch()
        let server = try await HermesTestServer.start { request in
            guard request.path == "/api/status" else { return TestHTTPResponse(200) }
            probed.signal()
            Thread.sleep(forTimeInterval: 2)
            return TestHTTPResponse(500, #"{"detail": "boom"}"#)
        }
        defer { server.stop() }

        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        defer { store.deleteToken(for: endpoint) }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        let connecting = Task { await model.connect(endpoint: endpoint, credentials: nil) }

        #expect(await probed.wait(), "the status probe never reached the server")
        model.disconnect()
        await connecting.value

        #expect(model.connectError == nil)
    }

    /// Two saved-server taps in a row. The first server is slow, so its
    /// connect finishes last — and must not clobber the second one, which is
    /// the connection actually on screen.
    @Test func aSecondConnectSurvivesTheFirstsLateProbe() async throws {
        let probed = TestLatch()
        let slow = try await HermesTestServer.start { request in
            guard request.path == "/api/status" else { return TestHTTPResponse(200) }
            probed.signal()
            Thread.sleep(forTimeInterval: 2)
            return TestHTTPResponse(200, #"{"auth_required": false, "version": "slow"}"#)
        }
        defer { slow.stop() }

        let fast = try await HermesTestServer.start { request in
            switch request.path {
            case "/api/status":
                return TestHTTPResponse(
                    200, #"{"auth_required": false, "version": "fast"}"#)
            default:
                return TestHTTPResponse(200)
            }
        }
        defer { fast.stop() }

        let slowEndpoint = try ServerEndpoint.parse("http://127.0.0.1:\(slow.port)").endpoint
        let fastEndpoint = try ServerEndpoint.parse("http://127.0.0.1:\(fast.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        defer {
            store.deleteToken(for: slowEndpoint)
            store.deleteToken(for: fastEndpoint)
        }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }

        let first = Task { await model.connect(endpoint: slowEndpoint, credentials: nil) }
        #expect(await probed.wait(), "the first status probe never reached the server")

        await model.connect(endpoint: fastEndpoint, credentials: nil)
        let live = model.connection
        #expect(live != nil, "the second connect never installed a connection")
        #expect(model.serverStatus?.version == "fast")

        await first.value

        #expect(model.connection === live)
        #expect(model.serverStatus?.version == "fast")
        #expect(model.endpoint?.key == fastEndpoint.key)
    }
}
