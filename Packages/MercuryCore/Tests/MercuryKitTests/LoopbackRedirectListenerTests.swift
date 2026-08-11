import Foundation
import Testing

@testable import MercuryKit

@Suite("Loopback PKCE redirect listener")
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
