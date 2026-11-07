#if os(macOS)
    import AppKit
    import SwiftUI

    /// Settings › Voice: the global mute shortcut and its recorder.
    struct VoiceHotKeySettingsSection: View {
        let controller: VoiceHotKeyController
        @State private var recording = false
        @State private var monitor: Any?

        var body: some View {
            Section("Shortcuts") {
                LabeledContent("Mute shortcut") {
                    HStack {
                        Button(recordLabel) { recording ? stopRecording() : startRecording() }
                            .monospacedDigit()
                        Button("Clear") { controller.set(nil) }
                            .disabled(controller.hotKey == nil || recording)
                        Button("Reset") { controller.resetToDefault() }
                            .disabled(controller.hotKey == .defaultMute || recording)
                    }
                }
                if controller.registrationFailed {
                    Text("macOS refused that shortcut. Another app may be using it.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Text(
                    "Mutes or unmutes the running voice conversation from any app. It's active only during a conversation, and needs ⌘ or ⌃."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .onDisappear { stopRecording() }
        }

        private var recordLabel: String {
            if recording { return "Type shortcut…" }
            return controller.hotKey?.displayString ?? "Record Shortcut"
        }

        private func startRecording() {
            controller.suspend()
            recording = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { record(event) }
                return nil
            }
        }

        private func record(_ event: NSEvent) {
            if event.keyCode == 53 {  // Esc cancels
                stopRecording()
                return
            }
            let key = VoiceHotKey(
                keyCode: event.keyCode,
                flags: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            guard key.isValid else {
                NSSound.beep()
                return
            }
            controller.set(key)
            stopRecording()
        }

        private func stopRecording() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard recording else { return }
            recording = false
            controller.resume()
        }
    }
#endif
