import SwiftUI

/// The detail pane for `.voice`: the app's single conversation, or a
/// placeholder once it has ended.
struct VoiceConversationScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let host = model.voiceConversation {
            // Memberwise order: onEnd, profileDisplayName, controller.
            ConversationView(
                onEnd: { model.endVoice() },
                profileDisplayName: { model.profileDisplayName($0) },
                controller: host.controller
            )
            .id(ObjectIdentifier(host))
        } else {
            ContentUnavailableView(
                "No voice conversation", systemImage: "mic.slash",
                description: Text("Pick a session on the Voice tab to start talking."))
        }
    }
}
