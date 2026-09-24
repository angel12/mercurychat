import Foundation

/// Public web pages the app links to. Public because the app target calls it.
public enum MercuryLinks {
    /// The privacy policy: `docs/index.html`, served by GitHub Pages. App
    /// Review wants it reachable from inside the app (#101), so the connect
    /// screen shows it before sign-in and the Server menu and macOS Settings
    /// show it after.
    public static let privacyPolicy = URL(string: "https://angel12.github.io/mercurychat/")!
}
