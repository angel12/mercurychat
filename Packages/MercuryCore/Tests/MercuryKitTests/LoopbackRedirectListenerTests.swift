import Foundation
import Testing

@testable import MercuryKit

// Serialized: each test binds a real loopback socket and dials it with
// URLSession; running several listeners concurrently in one process makes
// accepts flaky under load.
@Suite("Loopback PKCE redirect listener", .serialized)
struct LoopbackRedirectListenerTests {
    @Test func catchesCodeAndState() async throws {
        let listener = LoopbackRedirectListener()
        let redirectURI = try await listener.start()
        #expect(redirectURI.hasPrefix("http://127.0.0.1:"))
        #expect(redirectURI.hasSuffix("/callback"))

        async let redirect = listener.waitForRedirect(timeout: 10)

        // Give the waiter a beat to install, then play the browser's part.
        try await Task.sleep(for: .milliseconds(100))
        let url = URL(string: "\(redirectURI)?code=abc123&state=csrf42")!
        let (body, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: body, encoding: .utf8)?.contains("Signed in") == true)

        let caught = try await redirect
        #expect(caught.code == "abc123")
        #expect(caught.state == "csrf42")
    }

    @Test func rejectsDuplicateSecurityParametersWithoutCrashing() async throws {
        let listener = LoopbackRedirectListener()
        let redirectURI = try await listener.start()

        async let redirect = listener.waitForRedirect(timeout: 10)
        try await Task.sleep(for: .milliseconds(100))

        // Duplicate `code` must get a 400 — and must not complete or kill
        // the pending flow.
        let dup = URL(string: "\(redirectURI)?code=a&code=b&state=x")!
        let (_, dupResponse) = try await URLSession.shared.data(from: dup)
        #expect((dupResponse as? HTTPURLResponse)?.statusCode == 400)

        // A legitimate redirect afterwards still completes the sign-in.
        let good = URL(string: "\(redirectURI)?code=abc123&state=csrf42")!
        let (_, goodResponse) = try await URLSession.shared.data(from: good)
        #expect((goodResponse as? HTTPURLResponse)?.statusCode == 200)

        let caught = try await redirect
        #expect(caught.code == "abc123")
        #expect(caught.state == "csrf42")
    }

    @Test func strayProbeWithoutQueryKeepsWaiting() async throws {
        let listener = LoopbackRedirectListener()
        let redirectURI = try await listener.start()

        async let redirect = listener.waitForRedirect(timeout: 10)
        try await Task.sleep(for: .milliseconds(100))

        // A `/callback` hit with neither `code` nor `error` is a stray local
        // probe, not the browser redirect: it must get a 400 — and must not
        // kill the pending flow (failing the waiter would shut the port).
        let probe = URL(string: redirectURI)!
        let (_, probeResponse) = try await URLSession.shared.data(from: probe)
        #expect((probeResponse as? HTTPURLResponse)?.statusCode == 400)

        // A legitimate redirect afterwards still completes the sign-in.
        let good = URL(string: "\(redirectURI)?code=abc123&state=csrf42")!
        let (_, goodResponse) = try await URLSession.shared.data(from: good)
        #expect((goodResponse as? HTTPURLResponse)?.statusCode == 200)

        let caught = try await redirect
        #expect(caught.code == "abc123")
        #expect(caught.state == "csrf42")
    }

    @Test func errorRedirectBodyDoesNotReflectQueryValue() async throws {
        let listener = LoopbackRedirectListener()
        let redirectURI = try await listener.start()

        let redirectTask = Task { try await listener.waitForRedirect(timeout: 10) }
        try await Task.sleep(for: .milliseconds(100))

        // `error` is attacker-controlled; its percent-decoded value must
        // never reach the HTML body as markup (reflected XSS at the
        // loopback origin).
        let url = URL(string: "\(redirectURI)?error=%3Cimg%20src%3Dx%3E")!
        let (body, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
        let html = String(data: body, encoding: .utf8) ?? ""
        #expect(!html.contains("<img"))

        await #expect(throws: LoopbackRedirectListener.ListenerError.self) {
            _ = try await redirectTask.value
        }
    }

    @Test func taskCancellationShutsDownListenerImmediately() async throws {
        let listener = LoopbackRedirectListener()
        let redirectURI = try await listener.start()

        let redirectTask = Task { try await listener.waitForRedirect(timeout: 300) }
        try await Task.sleep(for: .milliseconds(100))
        redirectTask.cancel()

        // The wait must resolve promptly (not after the 300s timeout).
        await #expect(throws: LoopbackRedirectListener.ListenerError.self) {
            _ = try await redirectTask.value
        }

        // The port is closed: a late callback cannot complete the stale flow.
        try await Task.sleep(for: .milliseconds(200))
        var probe = URLRequest(url: URL(string: "\(redirectURI)?code=late&state=x")!)
        probe.timeoutInterval = 2
        await #expect(throws: (any Error).self) {
            _ = try await URLSession.shared.data(for: probe)
        }
    }

    @Test func explicitCancelFailsPendingWait() async throws {
        let listener = LoopbackRedirectListener()
        _ = try await listener.start()

        let redirectTask = Task { try await listener.waitForRedirect(timeout: 300) }
        try await Task.sleep(for: .milliseconds(100))
        await listener.cancel()

        await #expect(throws: LoopbackRedirectListener.ListenerError.self) {
            _ = try await redirectTask.value
        }
    }

    @Test func rejectsRedirectWithoutCode() async throws {
        let listener = LoopbackRedirectListener()
        let redirectURI = try await listener.start()

        let redirectTask = Task { try await listener.waitForRedirect(timeout: 10) }
        try await Task.sleep(for: .milliseconds(100))

        let url = URL(string: "\(redirectURI)?error=access_denied")!
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)

        await #expect(throws: LoopbackRedirectListener.ListenerError.self) {
            _ = try await redirectTask.value
        }
    }
}
