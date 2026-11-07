import SwiftUI
import WidgetKit

@main
struct MercuryWidgetsBundle: WidgetBundle {
    var body: some Widget {
        VoiceLiveActivityWidget()
        VoiceQuickStartWidget()
        if #available(iOS 18.0, *) {
            VoiceQuickStartControl()
        }
    }
}
