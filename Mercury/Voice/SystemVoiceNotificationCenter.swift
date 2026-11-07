#if os(iOS) || os(visionOS)
    import Foundation
    import MercuryKit
    import UserNotifications

    @MainActor
    final class SystemVoiceNotificationCenter: VoiceNotificationCenter {
        private var center: UNUserNotificationCenter { .current() }

        func add(_ request: VoiceNotificationRequest) async {
            let content = UNMutableNotificationContent()
            content.title = request.title
            content.body = request.body
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = "voice"
            if let category = request.categoryID { content.categoryIdentifier = category }
            content.userInfo = [VoicePromptNotifier.promptKeyInfo: request.promptKey]
            try? await center.add(
                UNNotificationRequest(identifier: request.id, content: content, trigger: nil))
        }

        func remove(ids: [String]) {
            center.removeDeliveredNotifications(withIdentifiers: ids)
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }

        func delivered() async -> [DeliveredNotification] {
            await withCheckedContinuation { continuation in
                center.getDeliveredNotifications { notes in
                    let mapped = notes.map {
                        DeliveredNotification(
                            id: $0.request.identifier,
                            push: PushPayload(userInfo: $0.request.content.userInfo))
                    }
                    continuation.resume(returning: mapped)
                }
            }
        }

        func requestAuthorizationIfUndetermined() async {
            let status = await withCheckedContinuation { continuation in
                center.getNotificationSettings { continuation.resume(returning: $0.authorizationStatus) }
            }
            guard status == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }

        /// Approve once / Deny on a voice approval. Both need the device
        /// unlocked; neither brings the app forward.
        static func registerCategories() {
            let approve = UNNotificationAction(
                identifier: VoicePromptNotifier.approveActionID, title: "Approve once",
                options: [.authenticationRequired])
            let deny = UNNotificationAction(
                identifier: VoicePromptNotifier.denyActionID, title: "Deny",
                options: [.authenticationRequired, .destructive])
            let category = UNNotificationCategory(
                identifier: VoicePromptNotifier.categoryID, actions: [approve, deny],
                intentIdentifiers: [])
            UNUserNotificationCenter.current().setNotificationCategories([category])
        }
    }
#endif
