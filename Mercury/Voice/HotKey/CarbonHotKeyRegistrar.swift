#if os(macOS)
    import Carbon.HIToolbox
    import os

    /// Global hot keys through Carbon's `RegisterEventHotKey`: delivered to
    /// the app from any frontmost app, allowed in the App Sandbox, and needs
    /// no Accessibility permission (unlike an `NSEvent` global monitor).
    @MainActor
    final class CarbonHotKeyRegistrar: HotKeyRegistering {
        private var hotKeyRef: EventHotKeyRef?
        private var handlerRef: EventHandlerRef?
        private var onPress: (@MainActor () -> Void)?
        private static let signature: OSType = 0x4D52_4356  // 'MRCV'
        private static let log = Logger(subsystem: "com.spencermcguire.mercurychat", category: "hotkey")

        func register(_ hotKey: VoiceHotKey, onPress: @escaping @MainActor () -> Void) -> Bool {
            unregister()
            guard installHandler() else { return false }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                hotKey.keyCode, hotKey.carbonModifiers,
                EventHotKeyID(signature: Self.signature, id: 1),
                GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else {
                Self.log.error("RegisterEventHotKey failed: \(status)")
                return false
            }
            hotKeyRef = ref
            self.onPress = onPress
            return true
        }

        func unregister() {
            if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
            hotKeyRef = nil
            onPress = nil
        }

        fileprivate func pressed() { onPress?() }

        /// Installed once; the registrar lives as long as the app.
        private func installHandler() -> Bool {
            if handlerRef != nil { return true }
            var spec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(
                GetApplicationEventTarget(), carbonHotKeyHandler, 1, &spec,
                Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
            if status != noErr { Self.log.error("InstallEventHandler failed: \(status)") }
            return status == noErr
        }
    }

    /// Carbon delivers application-target events on the main thread.
    private func carbonHotKeyHandler(
        _: EventHandlerCallRef?, _: EventRef?, _ userData: UnsafeMutableRawPointer?
    ) -> OSStatus {
        guard let userData else { return OSStatus(eventNotHandledErr) }
        nonisolated(unsafe) let pointer = userData
        MainActor.assumeIsolated {
            Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(pointer).takeUnretainedValue().pressed()
        }
        return noErr
    }
#endif
