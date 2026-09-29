#if os(iOS)
    import MercuryKit
    import UIKit
    import UserNotifications

    /// APNs and notification-center callbacks, forwarded to AppModel / PushCoordinator.
    /// `PushPayload` (Sendable) is decoded off the main actor and crosses into it.
    @MainActor
    final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
        /// Set by MercuryApp's first `.task`.
        weak var model: AppModel?

        func application(
            _ application: UIApplication,
            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
        ) -> Bool {
            UNUserNotificationCenter.current().delegate = self
            return true
        }

        func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
            guard let model else { return }
            Task { await model.push.didRegister(deviceToken: deviceToken) }
        }

        func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
            model?.push.didFailToRegister(error)
        }

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter, willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            guard let payload = PushPayload(userInfo: notification.request.content.userInfo) else {
                return [.banner, .sound, .list]
            }
            return await shouldPresent(payload) ? [.banner, .sound, .list] : []
        }

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
        ) async {
            guard let payload = PushPayload(userInfo: response.notification.request.content.userInfo) else { return }
            await open(payload)
        }

        private func shouldPresent(_ payload: PushPayload) async -> Bool {
            guard let model else { return true }
            let route = await model.push.route(for: payload)
            return model.shouldPresentPush(route, appActive: UIApplication.shared.applicationState == .active)
        }

        private func open(_ payload: PushPayload) async {
            guard let model else { return }
            let route = await model.push.route(for: payload)
            await model.openPushRoute(route)
        }
    }
#endif
