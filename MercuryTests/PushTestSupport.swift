import Foundation
import MercuryKit
import Security

/// Dictionary-backed SecItem closures for PushPairingStore (tests never touch the real Keychain).
final class InMemoryPushKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    private static func key(_ query: [String: Any]) -> String {
        "\(query[kSecAttrService as String] as? String ?? "")|\(query[kSecAttrAccount as String] as? String ?? "")"
    }

    var calls: KeychainCalls {
        KeychainCalls(
            update: { [self] query, attributes in
                lock.withLock {
                    let key = Self.key(query as? [String: Any] ?? [:])
                    guard items[key] != nil else { return errSecItemNotFound }
                    items[key] = (attributes as? [String: Any])?[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            },
            add: { [self] item in
                lock.withLock {
                    let dict = item as? [String: Any] ?? [:]
                    items[Self.key(dict)] = dict[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            },
            delete: { [self] query in
                lock.withLock {
                    items.removeValue(forKey: Self.key(query as? [String: Any] ?? [:])) == nil
                        ? errSecItemNotFound : errSecSuccess
                }
            })
    }

    var read: PushPairingStore.Read {
        { [self] query in
            lock.withLock {
                let data = items[Self.key(query as? [String: Any] ?? [:])]
                return (data == nil ? errSecItemNotFound : errSecSuccess, data)
            }
        }
    }
}

/// A scriptable PushSystem. `onRegister` simulates APNs delivering a token.
@MainActor
final class FakePushSystem: PushSystem {
    var status: PushAuthorization = .notDetermined
    var grant = true
    private(set) var registerCalls = 0
    private(set) var requestCalls = 0
    var onRegister: (@MainActor () -> Void)?
    let deviceName = "Test iPhone"

    func authorizationStatus() async -> PushAuthorization { status }
    func requestAuthorization() async -> Bool {
        requestCalls += 1
        status = grant ? .authorized : .denied
        return grant
    }
    func registerForRemoteNotifications() {
        registerCalls += 1
        onRegister?()
    }
    func openSystemSettings() {}
}

/// Stateful fake of the Mercury Push relay (/v1/...) and the Hermes plugin
/// (/api/plugins/mercury_push/devices?profile=...), served by HermesTestServer.
final class FakePushBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var installations: [String: (secret: String, token: String)] = [:]
    private var codes: [String: String] = [:]
    private var devices: [String: (installation: String, profile: String, active: Bool)] = [:]
    private var counter = 0
    private var _log: [String] = []
    /// Plugin override for the next plugin call(s): (status, body).
    var pluginOverride: (Int, String)?
    var log: [String] { lock.withLock { _log } }
    func deviceIDs(profile: String) -> [String] {
        lock.withLock { devices.filter { $0.value.profile == profile }.map(\.key).sorted() }
    }
    func deactivate(_ id: String) { lock.withLock { devices[id]?.active = false } }
    func dropInstallations() { lock.withLock { installations.removeAll() } }

    private func next(_ prefix: String) -> String { counter += 1; return "\(prefix)_\(counter)" }

    /// Returns nil for paths it doesn't own, so a test's own handler can answer them.
    func handle(_ request: TestHTTPRequest) -> TestHTTPResponse? {
        lock.withLock {
            let body = (try? JSONDecoder().decode(JSONValue.self, from: request.body)) ?? .object([:])
            let bearer = request.headers["authorization"].map { String($0.dropFirst("Bearer ".count)) }
            if request.path.hasPrefix("/v1/") {
                _log.append("\(request.method) \(request.path)")
                return relay(request.method, request.path, body, bearer)
            }
            if request.path.hasPrefix("/api/plugins/mercury_push/devices") {
                let profile = request.query.replacingOccurrences(of: "profile=", with: "")
                _log.append("\(request.method) \(request.path)?profile=\(profile)")
                return plugin(request.method, request.path, profile, body)
            }
            return nil
        }
    }

    private func relay(_ method: String, _ path: String, _ body: JSONValue, _ bearer: String?) -> TestHTTPResponse {
        let unauthorized = TestHTTPResponse(401, #"{"error":"credential_invalid","message":"x"}"#)
        if method == "POST", path == "/v1/installations" {
            let id = next("inst"), secret = next("secret"), code = next("CODE")
            installations[id] = (secret, body["device_token"]?.stringValue ?? "")
            codes[code] = id
            return TestHTTPResponse(201, #"{"installation_id":"\#(id)","installation_secret":"\#(secret)","pairing_code":"\#(code)","pairing_expires_at":"2026-09-21T14:13:20Z"}"#)
        }
        let parts = path.split(separator: "/").map(String.init)  // v1, installations, id, (pairing-codes)
        guard parts.count >= 3, let current = installations[parts[2]], current.secret == bearer else { return unauthorized }
        switch (method, parts.count) {
        case ("PUT", 3):
            if let token = body["device_token"]?.stringValue { installations[parts[2]]?.token = token }
            return TestHTTPResponse(200, #"{"ok":true}"#)
        case ("POST", 4):
            let code = next("CODE")
            codes[code] = parts[2]
            return TestHTTPResponse(201, #"{"pairing_code":"\#(code)","pairing_expires_at":"2026-09-21T14:13:20Z"}"#)
        case ("DELETE", 3):
            installations[parts[2]] = nil
            return TestHTTPResponse(204, "")
        default:
            return TestHTTPResponse(404, #"{"error":"not_found"}"#)
        }
    }

    private func plugin(_ method: String, _ path: String, _ profile: String, _ body: JSONValue) -> TestHTTPResponse {
        if let (status, text) = pluginOverride { return TestHTTPResponse(status, text) }
        let base = "/api/plugins/mercury_push/devices"
        if method == "POST", path == base {
            guard let installation = codes.removeValue(forKey: body["pairing_code"]?.stringValue ?? ""),
                installations[installation] != nil
            else { return TestHTTPResponse(502, #"{"error":"relay_error","relay_error":"pairing_code_invalid"}"#) }
            devices = devices.filter { !($0.value.installation == installation && $0.value.profile == profile) }
            let id = next("dev")
            devices[id] = (installation, profile, true)
            return TestHTTPResponse(201, #"{"device_id":"\#(id)","profile":"\#(profile)"}"#)
        }
        if method == "GET", path == base {
            let rows = devices.filter { $0.value.profile == profile }.map {
                #"{"device_id":"\#($0.key)","device_name":"Test iPhone","preferences":{},"paired_at":null,"last_delivery_at":null,"last_error":null,"active":\#($0.value.active)}"#
            }
            return TestHTTPResponse(200, "[\(rows.joined(separator: ","))]")
        }
        if path.hasPrefix(base + "/") {
            let rest = String(path.dropFirst(base.count + 1))
            let id = rest.components(separatedBy: "/")[0]
            guard devices[id]?.profile == profile else { return TestHTTPResponse(404, #"{"error":"device_not_found"}"#) }
            switch method {
            case "DELETE":
                devices[id] = nil
                return TestHTTPResponse(204, "")
            case "PATCH":
                return TestHTTPResponse(200, #"{"device_id":"\#(id)","device_name":"Test iPhone","preferences":{},"active":true}"#)
            case "POST":
                return TestHTTPResponse(202, #"{"event_id":"e-1"}"#)
            default:
                return TestHTTPResponse(405, "")
            }
        }
        return TestHTTPResponse(404, #"{"detail":"Not Found"}"#)
    }
}
