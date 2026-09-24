import Foundation
import Testing

/// Issue #100: Apple rejects an upload whose app code uses a required-reason
/// API without declaring it in the app's own PrivacyInfo.xcprivacy. The app's
/// only such use is UserDefaults for its own settings (saved servers, last
/// server, the allowed-plaintext list) — reason CA92.1, data read and written
/// only by this app (there is no app group). MercuryKit ships its own manifest
/// for its systemUptime use, so that is deliberately not declared here.
@Suite("Privacy manifest")
struct PrivacyManifestTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func manifest() throws -> [String: Any] {
        let url = repoRoot.appending(path: "Mercury/PrivacyInfo.xcprivacy")
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(object as? [String: Any])
    }

    private static func declaredReasons() throws -> [String: [String]] {
        let accessed = try #require(manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        return Dictionary(
            uniqueKeysWithValues: accessed.map {
                ($0["NSPrivacyAccessedAPIType"] as? String ?? "",
                 $0["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [])
            })
    }

    @Test func declaresUserDefaultsForThisAppOnly() throws {
        #expect(try Self.declaredReasons() == ["NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"]])
    }

    @Test func declaresNoTrackingAndNoCollectedData() throws {
        // Matches PRIVACY.md: the developer collects nothing.
        let manifest = try Self.manifest()
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)
        #expect((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
    }

    /// A new use of a listed API in app code must come with a declaration.
    /// Patterns follow Apple's required-reason API list.
    @Test func everyListedAPIUsedByAppCodeIsDeclared() throws {
        let categories: [String: [String]] = [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["UserDefaults", "@AppStorage"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["systemUptime", "mach_absolute_time"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": [
                "creationDate", "modificationDate", "contentModificationDate",
                "attributesOfItem", "getattrlist", "fstat(", "lstat(",
            ],
            "NSPrivacyAccessedAPICategoryDiskSpace": [
                "volumeAvailableCapacity", "volumeTotalCapacity", "systemFreeSize", "statfs",
            ],
            "NSPrivacyAccessedAPICategoryActiveKeyboards": ["activeInputModes"],
        ]
        // ChatCore links statically into the app, so its code counts too.
        let sources = try ["Mercury", "Packages/MercuryCore/Sources"].flatMap { root in
            try FileManager.default
                .subpathsOfDirectory(atPath: Self.repoRoot.appending(path: root).path)
                .filter { $0.hasSuffix(".swift") }
                .map { "\(root)/\($0)" }
        }
        var used: Set<String> = []
        for path in sources {
            let text = try String(contentsOf: Self.repoRoot.appending(path: path), encoding: .utf8)
            let code = text.split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for (category, symbols) in categories where symbols.contains(where: code.contains) {
                used.insert(category)
            }
        }
        #expect(!sources.isEmpty)
        #expect(used.isSubset(of: Set(try Self.declaredReasons().keys)), "undeclared: \(used)")
    }
}
