import Foundation
import Testing

@testable import ChatCore

/// #101: App Review guideline 5.1.1(i) wants the privacy policy reachable
/// from inside the app, over HTTPS. The app links `MercuryLinks.privacyPolicy`,
/// which is the GitHub Pages site built from `docs/`.
@Suite("MercuryLinks")
struct MercuryLinksTests {
    @Test func privacyPolicyIsTheHTTPSPagesSite() {
        let url = MercuryLinks.privacyPolicy
        #expect(url.scheme == "https")
        #expect(url.host() == "angel12.github.io")
        #expect(url.path() == "/mercurychat/")
    }

    /// Pages serves `docs/index.html` at that path, so the page the app links
    /// must be the policy itself.
    @Test func pagesRootIsThePolicy() throws {
        let page = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ChatCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // MercuryCore
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
            .appending(path: "docs/index.html")
        let html = try String(contentsOf: page, encoding: .utf8)
        #expect(html.contains("<title>Privacy Policy — Mercury Chat</title>"))
    }
}
