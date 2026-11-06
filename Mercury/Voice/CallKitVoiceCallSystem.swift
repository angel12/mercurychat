import Foundation

#if os(iOS) || os(visionOS)
    import AVFoundation
    import CallKit
    import os

    /// CallKit behind `VoiceCallSystem` (spec §1). The provider's delegate
    /// runs on the main queue (`queue: nil`); the `@preconcurrency`
    /// conformance lets the main-actor methods serve it directly.
    @MainActor
    final class CallKitVoiceCallSystem: NSObject, VoiceCallSystem, @preconcurrency CXProviderDelegate {
        weak var events: (any VoiceCallSystemEvents)?
        private let provider: CXProvider
        private let callController = CXCallController()

        override init() {
            let configuration = CXProviderConfiguration()
            configuration.supportsVideo = false
            configuration.maximumCallGroups = 1
            configuration.maximumCallsPerCallGroup = 1
            configuration.includesCallsInRecents = false
            configuration.supportedHandleTypes = [.generic]
            provider = CXProvider(configuration: configuration)
            super.init()
            provider.setDelegate(self, queue: nil)
        }

        func requestStart(_ call: UUID, displayName: String) async throws {
            let handle = CXHandle(type: .generic, value: displayName)
            let action = CXStartCallAction(call: call, handle: handle)
            action.isVideo = false
            try await perform(action)
            let update = CXCallUpdate()
            update.remoteHandle = handle
            update.localizedCallerName = displayName
            update.hasVideo = false
            update.supportsHolding = true
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.supportsDTMF = false
            provider.reportCall(with: call, updated: update)
        }

        func requestEnd(_ call: UUID) async throws {
            try await perform(CXEndCallAction(call: call))
        }

        func requestMute(_ call: UUID, muted: Bool) async throws {
            try await perform(CXSetMutedCallAction(call: call, muted: muted))
        }

        func reportEnded(_ call: UUID, failed: Bool) {
            provider.reportCall(with: call, endedAt: nil, reason: failed ? .failed : .remoteEnded)
        }

        /// The completion-handler request bridged to async: the transaction
        /// is built and consumed on the main actor, so nothing non-Sendable
        /// crosses an isolation boundary.
        private func perform(_ action: CXAction) async throws {
            let controller = callController
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                controller.request(CXTransaction(action: action)) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        private static let log = Logger(subsystem: "Mercury", category: "VoiceCall")

        /// The kit's voice category, set before CallKit activates the
        /// session. Best effort: a failure is logged and the call goes on,
        /// since the kit sets the category again when it starts voice.
        private func configureAudioSession() {
            do {
                try AVAudioSession.sharedInstance().setCategory(
                    .playAndRecord, mode: .voiceChat,
                    options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
            } catch {
                Self.log.error(
                    "voice audio category failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // MARK: CXProviderDelegate

        func providerDidReset(_ provider: CXProvider) {
            events?.systemDidReset()
        }

        func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
            configureAudioSession()
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
            action.fulfill()
            provider.reportOutgoingCall(with: action.callUUID, connectedAt: nil)
        }

        func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
            action.fulfill()
            events?.systemDidEnd(action.callUUID)
        }

        func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
            action.fulfill()
            events?.systemDidSetMuted(action.callUUID, muted: action.isMuted)
        }

        func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
            // Audio follows didDeactivate / didActivate.
            action.fulfill()
        }

        func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
            events?.systemDidActivateAudio()
        }

        func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
            events?.systemDidDeactivateAudio()
        }
    }
#endif
