import Testing

@testable import ChatCore

/// #104: a token entered for one server must never ride along to another.
/// A token is bound to a server once it is used for it — autofilled from a
/// dashboard URL, or submitted with a Connect attempt — and changing the
/// server to a different endpoint clears it.
@Suite("ConnectFormState")
struct ConnectFormStateTests {
    @Test func pastedDashboardURLAutofillsTheToken() {
        var form = ConnectFormState()
        form.setServer("http://127.0.0.1:9119/?token=synthetic-a")
        #expect(form.token == "synthetic-a")
        #expect(form.connectToken == "synthetic-a")
        #expect(!form.tokenWasCleared)
    }

    @Test func autofilledTokenIsClearedWhenTheServerChanges() {
        var form = ConnectFormState()
        form.setServer("https://a.example/?token=synthetic-a")
        form.setServer("https://b.example")
        #expect(form.token.isEmpty)
        #expect(form.connectToken == nil)
        #expect(form.tokenWasCleared)
    }

    @Test func manualTokenIsClearedAfterAnAttemptWhenTheServerChanges() {
        var form = ConnectFormState()
        form.setServer("https://a.example")
        form.setToken("synthetic-a")
        form.recordAttempt()
        form.setServer("https://b.example")
        #expect(form.token.isEmpty)
        #expect(form.tokenWasCleared)
    }

    @Test func manualTokenBeforeAnyAttemptSurvivesTypingTheServer() {
        // Typing the server one character at a time after the token must
        // not wipe it: nothing has been sent anywhere yet.
        var form = ConnectFormState()
        form.setToken("synthetic-a")
        for end in ["h", "ht", "https://a", "https://a.example"] {
            form.setServer(end)
        }
        #expect(form.connectToken == "synthetic-a")
    }

    @Test func normalizedEquivalentEndpointKeepsTheToken() {
        var form = ConnectFormState()
        form.setServer("127.0.0.1:9119")
        form.setToken("synthetic-a")
        form.recordAttempt()
        form.setServer("http://127.0.0.1:9119/")
        #expect(form.connectToken == "synthetic-a")
        #expect(!form.tokenWasCleared)
    }

    @Test func droppingTheTokenQueryFromTheSameServerKeepsIt() {
        var form = ConnectFormState()
        form.setServer("http://127.0.0.1:9119/?token=synthetic-a")
        form.setServer("http://127.0.0.1:9119")
        #expect(form.connectToken == "synthetic-a")
    }

    @Test func schemeChangeIsADifferentEndpoint() {
        var form = ConnectFormState()
        form.setServer("http://a.example/?token=synthetic-a")
        form.setServer("https://a.example")
        #expect(form.connectToken == nil)
    }

    @Test func unparseableServerClearsABoundToken() {
        var form = ConnectFormState()
        form.setServer("https://a.example/?token=synthetic-a")
        form.setServer("")
        #expect(form.connectToken == nil)
    }

    @Test func enteringATokenAgainDismissesTheClearedNotice() {
        var form = ConnectFormState()
        form.setServer("https://a.example/?token=synthetic-a")
        form.setServer("https://b.example")
        form.setToken("synthetic-b")
        #expect(!form.tokenWasCleared)
        #expect(form.connectToken == "synthetic-b")
    }

    @Test func emptyTokenIsNoCredential() {
        var form = ConnectFormState()
        form.setServer("https://a.example")
        #expect(form.connectToken == nil)
    }
}
