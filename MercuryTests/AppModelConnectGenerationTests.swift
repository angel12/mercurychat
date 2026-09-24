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
    /// Holds one scripted request open until the test releases it, so the
    /// test's disconnect or second connect lands while that request is in
    /// flight however slowly the runner schedules it — a fixed sleep could
    /// expire first on a loaded machine and test the wrong ordering.
    final class RequestHold: @unchecked Sendable {
        let reached = TestLatch()
        private let released = DispatchSemaphore(value: 0)
        func release() { released.signal() }
        func wait() {
            reached.signal()
            _ = released.wait(timeout: .now() + 10)
        }
    }

    /// A disconnect while the status probe is still in flight. The probe's
    /// answer belongs to a connect the user has already abandoned, so none of
    /// it may reach the model.
    @Test func disconnectDuringTheProbePublishesNothing() async throws {
        let probe = RequestHold()
        let server = try await HermesTestServer.start { request in
            guard request.path == "/api/status" else { return TestHTTPResponse(200) }
            // Hold the probe open so the disconnect below lands while
            // connect() is still suspended on it.
            probe.wait()
            return TestHTTPResponse(
                200, #"{"auth_required": false, "version": "abandoned"}"#)
        }
        defer { server.stop() }
        defer { probe.release() }

        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        defer { try? store.deleteToken(for: endpoint) }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        let connecting = Task { await model.connect(endpoint: endpoint, credentials: nil) }

        #expect(await probe.reached.wait(), "the status probe never reached the server")
        model.disconnect()
        probe.release()
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
        let validation = RequestHold()
        let server = try await HermesTestServer.start { request in
            switch request.path {
            case "/api/status":
                return TestHTTPResponse(200, #"{"auth_required": false}"#)
            case "/api/profiles/active":
                validation.wait()
                return TestHTTPResponse(200, "{}")
            default:
                return TestHTTPResponse(200)
            }
        }
        defer { server.stop() }
        defer { validation.release() }

        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        defer { try? store.deleteToken(for: endpoint) }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        let connecting = Task { await model.connect(endpoint: endpoint, credentials: nil) }

        #expect(await validation.reached.wait(), "token validation never reached the server")
        model.disconnect()
        validation.release()
        await connecting.value

        #expect(model.connection == nil)
        #expect(model.phase == .stopped)
    }

    /// A probe that fails *after* the user walked away must not repaint the
    /// connect screen with an error for a server they are no longer trying.
    @Test func aFailedProbeAfterDisconnectShowsNoError() async throws {
        let probe = RequestHold()
        let server = try await HermesTestServer.start { request in
            guard request.path == "/api/status" else { return TestHTTPResponse(200) }
            probe.wait()
            return TestHTTPResponse(500, #"{"detail": "boom"}"#)
        }
        defer { server.stop() }
        defer { probe.release() }

        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
        defer { try? store.deleteToken(for: endpoint) }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }
        let connecting = Task { await model.connect(endpoint: endpoint, credentials: nil) }

        #expect(await probe.reached.wait(), "the status probe never reached the server")
        model.disconnect()
        probe.release()
        await connecting.value

        #expect(model.connectError == nil)
    }

    /// Two saved-server taps in a row. The first server is slow, so its
    /// connect finishes last — and must not clobber the second one, which is
    /// the connection actually on screen.
    @Test func aSecondConnectSurvivesTheFirstsLateProbe() async throws {
        let slowProbe = RequestHold()
        let slow = try await HermesTestServer.start { request in
            guard request.path == "/api/status" else { return TestHTTPResponse(200) }
            slowProbe.wait()
            return TestHTTPResponse(200, #"{"auth_required": false, "version": "slow"}"#)
        }
        defer { slow.stop() }
        defer { slowProbe.release() }

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
            try? store.deleteToken(for: slowEndpoint)
            try? store.deleteToken(for: fastEndpoint)
        }

        let model = AppModel(tokenStore: store)
        defer { model.disconnect() }

        let first = Task { await model.connect(endpoint: slowEndpoint, credentials: nil) }
        #expect(await slowProbe.reached.wait(), "the first status probe never reached the server")

        await model.connect(endpoint: fastEndpoint, credentials: nil)
        let live = model.connection
        #expect(live != nil, "the second connect never installed a connection")
        #expect(model.serverStatus?.version == "fast")

        // Only now let the first server's probe answer, so the first connect
        // resumes strictly after the second one has installed its connection.
        slowProbe.release()
        await first.value

        #expect(model.connection === live)
        #expect(model.serverStatus?.version == "fast")
        #expect(model.endpoint?.key == fastEndpoint.key)
    }
}
