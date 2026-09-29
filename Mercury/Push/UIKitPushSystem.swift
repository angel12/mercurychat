#if os(iOS)
    import UIKit
    import UserNotifications

    @MainActor
    final class UIKitPushSystem: PushSystem {
        func authorizationStatus() async -> PushAuthorization {
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .authorized
            case .denied: return .denied
            default: return .notDetermined
            }
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
