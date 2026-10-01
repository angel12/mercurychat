#if os(iOS)
    import MercuryKit
    import UIKit
    import UserNotifications

    /// APNs and notification-center callbacks, forwarded to AppModel / PushCoordinator.
    /// `PushPayload` (Sendable) is decoded off the main actor and crosses into it.
    @MainActor
    final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
        /// Set by MercuryApp's first `.task`.
        weak var model: AppModel? {
            didSet {
                guard model != nil, let payload = pendingPayload else { return }
                pendingPayload = nil
                Task { await open(payload) }
            }
        }

        /// A tap that arrived before `model` was set (cold launch); latest wins.
        private var pendingPayload: PushPayload?

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

        // The completion-handler forms, not the async ones: UIKit asserts that these completion
        // handlers run on the main thread, and the async forms' bridging called them from a
        // background thread once the work finished — tapping a notification aborted the app.

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            let payload = PushPayload(userInfo: notification.request.content.userInfo)
            nonisolated(unsafe) let done = completionHandler
            Task { @MainActor in
                var show = true
                if let payload { show = await self.shouldPresent(payload) }
                done(show ? [.banner, .sound, .list] : [])
            }
        }

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            let payload = PushPayload(userInfo: response.notification.request.content.userInfo)
            nonisolated(unsafe) let done = completionHandler
            Task { @MainActor in
                // Acknowledge right away; routing may wait for a connection or a server switch.
                if let payload { Task { await self.open(payload) } }
                done()
            }
        }

        private func shouldPresent(_ payload: PushPayload) async -> Bool {
            guard let model else { return true }
            let route = await model.push.route(for: payload)
            return model.shouldPresentPush(route, appActive: UIApplication.shared.applicationState == .active)
        }

        private func open(_ payload: PushPayload) async {
            guard let model else {
                pendingPayload = payload
                return
            }
            let route = await model.push.route(for: payload)
            await model.openPushRoute(route)
        }
    }
#endif
