import Foundation
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// System destinations the app links out to.
enum SystemLinks {
    /// The system's microphone-privacy setting for this app: the iOS
    /// Settings page for the app, or the macOS Privacy & Security pane.
    @MainActor
    static func openMicrophonePrivacySettings() {
        #if os(macOS)
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            NSWorkspace.shared.open(url)
        #else
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        #endif
    }
}
