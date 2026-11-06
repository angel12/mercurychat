import Foundation
import MercuryKit

struct VoiceNotificationRequest: Equatable, Sendable {
    let id: String
    let title: String
    let body: String
    let categoryID: String?
    let promptKey: String
}

struct DeliveredNotification: Sendable {
    let id: String
    /// The Mercury Push payload, when the notification is a push.
    let push: PushPayload?
}

/// The system notification center (UserNotifications in the app, a fake in tests).
@MainActor protocol VoiceNotificationCenter: AnyObject {
    func add(_ request: VoiceNotificationRequest) async
    func remove(ids: [String])
    func delivered() async -> [DeliveredNotification]
    func requestAuthorizationIfUndetermined() async
}

enum VoiceNotificationAction: Sendable, Equatable { case open, approveOnce, deny }

/// Lock-screen reach for a voice conversation's prompts (spec §2): one
/// fixed-text, time-sensitive notification for the front prompt while the app
/// isn't active, withdrawn once the prompt settles or the app comes forward.
/// A posted approval also sweeps away Mercury Push's copy of it.
@MainActor
final class VoicePromptNotifier {
    static let categoryID = "voice-approval"
    static let approveActionID = "voice-approve-once"
    static let denyActionID = "voice-deny"
    static let promptKeyInfo = "voicePrompt"

    static func identifier(_ key: String) -> String { "voice-prompt.\(key)" }

    static func action(forIdentifier id: String) -> VoiceNotificationAction {
        switch id {
        case approveActionID: .approveOnce
        case denyActionID: .deny
        default: .open
        }
    }

    private let center: (any VoiceNotificationCenter)?
    private let isAppActive: @MainActor () -> Bool
    private let sweepDelay: Duration
    private let sleep: @Sendable (Duration) async -> Void

    private struct Current {
        var prompt: VoicePrompt
        var title: String
        var storedSessionID: String?
    }
    private var current: Current?
    private var posted: Set<String> = []
    private var adds: [String: Task<Void, Never>] = [:]
    private var sweeps: [String: Task<Void, Never>] = [:]

    init(
        center: (any VoiceNotificationCenter)?, isAppActive: @escaping @MainActor () -> Bool,
        sweepDelay: Duration = .seconds(4),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.center = center
        self.isAppActive = isAppActive
        self.sweepDelay = sweepDelay
        self.sleep = sleep
    }

    func promptChanged(_ prompt: VoicePrompt?, title: String, storedSessionID: String?) {
        if let old = current?.prompt, old.key != prompt?.key { withdraw(old.key) }
        guard let prompt else {
            current = nil
            return
        }
        let isNew = current?.prompt.key != prompt.key
        current = Current(prompt: prompt, title: title, storedSessionID: storedSessionID)
        if isNew, !isAppActive() { post() }
    }

    func appEnteredBackground() {
        guard let current, !posted.contains(Self.identifier(current.prompt.key)) else { return }
        post()
    }

    func appBecameActive() {
        for id in posted { withdrawID(id) }
    }

    func conversationEnded() {
        if let old = current?.prompt { withdraw(old.key) }
        current = nil
    }

    func requestAuthorizationIfNeeded() {
        guard let center else { return }
        Task { await center.requestAuthorizationIfUndetermined() }
    }

    private func withdraw(_ key: String) { withdrawID(Self.identifier(key)) }

    /// Every removal waits for that id's add to land, so a prompt that settles
    /// inside the add window can't leave a stale notification behind.
    private func withdrawID(_ id: String) {
        guard posted.remove(id) != nil else { return }
        sweeps.removeValue(forKey: id)?.cancel()
        let add = adds.removeValue(forKey: id)
        guard let center else { return }
        Task {
            await add?.value
            center.remove(ids: [id])
        }
    }

    private func post() {
        guard let center, let current else { return }
        let prompt = current.prompt
        let id = Self.identifier(prompt.key)
        posted.insert(id)
        let request = VoiceNotificationRequest(
            id: id, title: current.title, body: prompt.body,
            categoryID: prompt.kind == .approval ? Self.categoryID : nil,
            promptKey: prompt.key)
        let session = current.storedSessionID
        let delay = sweepDelay
        let sleep = self.sleep
        let add = Task { await center.add(request) }
        adds[id] = add
        sweeps[id]?.cancel()
        guard prompt.kind == .approval else { return }
        sweeps[id] = Task { [weak self] in
            await add.value
            guard !Task.isCancelled else { return }
            await self?.sweepPushApprovals(for: prompt, session: session)
            await sleep(delay)
            guard !Task.isCancelled else { return }
            await self?.sweepPushApprovals(for: prompt, session: session)
        }
    }

    /// Mercury Push's copy of this approval, if it was delivered too.
    private func sweepPushApprovals(for prompt: VoicePrompt, session: String?) async {
        guard let center else { return }
        let ids = await center.delivered().compactMap { note -> String? in
            guard let push = note.push, push.kind == .approval else { return nil }
            if let requestID = prompt.pushRequestID, let pushed = push.requestID {
                return pushed == requestID ? note.id : nil
            }
            guard let session else { return nil }
            return push.sessionID == session ? note.id : nil
        }
        if !ids.isEmpty, !Task.isCancelled { center.remove(ids: ids) }
    }
}
