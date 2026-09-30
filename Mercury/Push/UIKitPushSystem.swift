#if os(iOS)
    import UIKit
    import UserNotifications

    @MainActor
    final class UIKitPushSystem: PushSystem {
        func authorizationStatus() async -> PushAuthorization {
            switch await Self.systemAuthorizationStatus() {
            case .authorized, .provisional, .ephemeral: return .authorized
            case .denied: return .denied
            default: return .notDetermined
            }
        }

        /// Reads the settings off the main actor and returns only the (Sendable) status:
        /// older SDKs don't mark `UNNotificationSettings` Sendable.
        private nonisolated static func systemAuthorizationStatus() async -> UNAuthorizationStatus {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }

        func requestAuthorization() async -> Bool {
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        }

        func registerForRemoteNotifications() {
            UIApplication.shared.registerForRemoteNotifications()
        }

        func openSystemSettings() {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }

        var deviceName: String { UIDevice.current.name }
    }
#endif
