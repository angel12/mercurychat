import Foundation
import Testing

@testable import MercuryKit

/// Round-trips against the real keychain under a throwaway service name;
/// every test cleans up its item. The point of the suite is the write
/// contract: set/delete report success instead of silently discarding
/// their `OSStatus` (a locked keychain must not silently keep stale
/// credentials).
@Suite("KeychainTokenStore", .serialized)
struct KeychainTokenStoreTests {
    private let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
    private let endpoint = try! ServerEndpoint.parse("http://127.0.0.1:8787").endpoint

    @Test func setReportsSuccessAndRoundTrips() {
        defer { store.deleteToken(for: endpoint) }
        #expect(store.setToken("tok-1", for: endpoint))
        #expect(store.token(for: endpoint) == "tok-1")
    }

    @Test func overwriteReportsSuccessAndWins() {
        defer { store.deleteToken(for: endpoint) }
        #expect(store.setToken("tok-1", for: endpoint))
        #expect(store.setToken("tok-2", for: endpoint))
        #expect(store.token(for: endpoint) == "tok-2")
    }

    @Test func deleteRemovesTheItem() {
        #expect(store.setToken("tok-1", for: endpoint))
        store.deleteToken(for: endpoint)
        #expect(store.token(for: endpoint) == nil)
    }

    @Test func setCredentialsReportsSuccessAndRoundTrips() {
        defer { store.deleteToken(for: endpoint) }
        #expect(store.setCredentials(.sessionToken("tok-3"), for: endpoint))
        #expect(store.credentials(for: endpoint) == .sessionToken("tok-3"))
    }

    @Test func settingNilTokenDeletes() {
        #expect(store.setToken("tok-4", for: endpoint))
        #expect(store.setToken(nil, for: endpoint))
        #expect(store.token(for: endpoint) == nil)
    }
}
