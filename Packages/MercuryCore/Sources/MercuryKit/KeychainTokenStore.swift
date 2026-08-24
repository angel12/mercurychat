import Foundation
import Security

/// Per-server credential storage backed by the Keychain.
///
/// Items are keyed by `ServerEndpoint.key` (scheme://host:port) and hold a
/// JSON-encoded `ServerCredentials` (session token or password-session
/// tokens). Items written before credentials existed are raw token strings —
/// read back as `.sessionToken`. Non-secret preferences (server list, last
/// server) belong in UserDefaults, not here.
public struct KeychainTokenStore: Sendable {
    private let service: String

    public init(service: String = "com.mercury.tokens") {
        self.service = service
    }

    // MARK: Credentials (either mode)

    public func credentials(for endpoint: ServerEndpoint) -> ServerCredentials? {
        guard let raw = token(for: endpoint) else { return nil }
        if let decoded = try? JSONDecoder().decode(
            ServerCredentials.self, from: Data(raw.utf8))
        {
            return decoded
        }
        return .sessionToken(raw)  // legacy pre-credentials item
    }

    /// Returns false when the keychain write failed — silently keeping the
    /// old item means presenting stale credentials next launch, so callers
    /// should surface it.
    @discardableResult
    public func setCredentials(
        _ credentials: ServerCredentials?, for endpoint: ServerEndpoint
    ) -> Bool {
        guard let credentials,
            let data = try? JSONEncoder().encode(credentials),
            let json = String(data: data, encoding: .utf8)
        else {
            deleteToken(for: endpoint)
            return true
        }
        return setToken(json, for: endpoint)
    }

    public func token(for endpoint: ServerEndpoint) -> String? {
        var query = baseQuery(account: endpoint.key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func setToken(_ token: String?, for endpoint: ServerEndpoint) -> Bool {
        guard let token, !token.isEmpty else {
            deleteToken(for: endpoint)
            return true
        }
        let data = Data(token.utf8)
        let query = baseQuery(account: endpoint.key)
        let update: [String: Any] = [kSecValueData as String: data]

        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            // ThisDeviceOnly: these are per-server session credentials —
            // they must not spread to other devices via iCloud Keychain.
            add[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    public func deleteToken(for endpoint: ServerEndpoint) {
        SecItemDelete(baseQuery(account: endpoint.key) as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
