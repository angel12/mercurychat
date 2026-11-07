import Foundation
@testable import MercuryVoiceEngine
import Testing

@MainActor
@Suite("Voice activity phase")
struct VoiceActivityPhaseTests {
    private func state(
        _ status: ConversationStatus = .listening, muted: Bool = false, paused: Bool = false
    ) -> ConversationUIState {
        ConversationUIState(status: status, muted: muted, paused: paused)
    }

    @Test func priorityOrder() {
        let p = VoiceConversationHost.activityPhase
        #expect(p(true, true, true, state(.speaking, muted: true, paused: true)) == .needsInput)
        #expect(p(false, true, true, state(.speaking, muted: true, paused: true)) == .reconnecting)
        #expect(p(false, true, false, state(.speaking, muted: true, paused: true)) == .waiting)
        #expect(p(false, false, false, state(.speaking, muted: true, paused: true)) == .paused)
        #expect(p(false, false, false, state(.speaking, muted: true)) == .muted)
        #expect(p(false, false, false, state(.idle)) == .paused)
        #expect(p(false, false, false, state(.listening)) == .listening)
        #expect(p(false, false, false, state(.transcribing)) == .transcribing)
        #expect(p(false, false, false, state(.thinking)) == .thinking)
        #expect(p(false, false, false, state(.speaking)) == .speaking)
    }

    @Test func barStatusIsThePhaseLabel() {
        for needsInput in [false, true] {
            for waiting in [false, true] {
                for status: ConversationStatus in [
                    .idle, .listening, .transcribing, .thinking, .speaking,
                ] {
                    for muted in [false, true] {
                        for paused in [false, true] {
                            let s = state(status, muted: muted, paused: paused)
                            #expect(
                                VoiceConversationHost.barStatus(
                                    needsInput: needsInput, waiting: waiting, state: s)
                                    == VoiceConversationHost.activityPhase(
                                        needsInput: needsInput, waiting: waiting,
                                        reconnecting: false, state: s
                                    ).label)
                        }
                    }
                }
            }
        }
        #expect(VoiceConversationHost.needsInputStatus == VoiceActivityPhase.needsInput.label)
    }

    @Test func labels() {
        let all: [VoiceActivityPhase] = [
            .listening, .transcribing, .thinking, .speaking, .waiting, .needsInput, .paused,
            .muted, .reconnecting,
        ]
        #expect(
            all.map(\.label) == [
                "Listening", "Transcribing", "Thinking", "Speaking", "Waiting", "Needs your input",
                "Paused", "Muted", "Reconnecting",
            ])
        #expect(all.filter(\.needsAttention) == [.needsInput])
    }
}
