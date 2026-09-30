import Foundation

/// The notification permission as the app sees it.
enum PushAuthorization: Equatable, Sendable {
    case notDetermined, denied, authorized
}

/// The Apple push APIs PushCoordinator needs, behind a protocol so the
/// coordinator stays platform-neutral and unit-testable on macOS.
@MainActor
protocol PushSystem: AnyObject {
    func authorizationStatus() async -> PushAuthorization
    func requestAuthorization() async -> Bool
    func registerForRemoteNotifications()
    func openSystemSettings()
    /// Shown in the server's device list (`hermes mercury-push status`).
    var deviceName: String { get }
}

/// Push is iOS-only in v1: macOS and visionOS get an inert system.
@MainActor
final class NoPushSystem: PushSystem {
    func authorizationStatus() async -> PushAuthorization { .denied }
    func requestAuthorization() async -> Bool { false }
    func registerForRemoteNotifications() {}
    func openSystemSettings() {}
    let deviceName = "Mercury Chat"
}

enum PushSystemFactory {
    @MainActor static func make() -> any PushSystem {
        #if os(iOS)
            UIKitPushSystem()
        #else
            NoPushSystem()
        #endif
    }
}
