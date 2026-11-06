import Foundation
import MercuryKit
@testable import MercuryVoiceEngine
import Testing

extension SharedMeterTests {
    @MainActor
    @Suite("Voice call hooks")
    struct VoiceCallHooksTests {
        /// The mic must not arm before the call's audio session is active.
        @Test func beginWaitsForAudioReadyBeforeArming() async throws {
            let voices = ConversationRecorder()
            voices.script = { _, service in
                service.enqueueCreate(Fixtures.resumeResult(runtimeID: "rt-a", storedID: "stored-a"))
            }
            let controller = voices.make(connection: makeUndialedConnection(), profile: nil)
            let gate = CallHooksGate()
            controller.audioReady = { await gate.wait() }
            let begin = Task { await controller.begin(mode: .create(cwd: nil, title: nil)) }
            try await Task.sleep(for: .milliseconds(200))
            #expect(voices.launches[0].recorder.startCalls == 0)
            gate.open()
            await begin.value
            #expect(await eventually { voices.launches[0].recorder.startCalls > 0 })
            await controller.teardown()
        }

        @Test func setMutedIsIdempotentAndReportsChanges() async throws {
            let voices = ConversationRecorder()
            voices.script = { _, service in
                service.enqueueCreate(Fixtures.resumeResult(runtimeID: "rt-a", storedID: "stored-a"))
            }
            let controller = voices.make(connection: makeUndialedConnection(), profile: nil)
            var reported: [Bool] = []
            controller.onMuteChanged = { reported.append($0) }
            await controller.begin(mode: .create(cwd: nil, title: nil))
            controller.setMuted(true)
            #expect(await eventually { controller.voiceState.muted })
            controller.setMuted(true)
            try await Task.sleep(for: .milliseconds(100))
            #expect(controller.voiceState.muted)
            controller.setMuted(false)
            #expect(await eventually { !controller.voiceState.muted })
            #expect(reported == [true, false])
            await controller.teardown()
        }

        /// Back-to-back calls with no yield between them: the second must see
        /// the first's effect, not the lagging UI state.
        @Test func backToBackSetMutedCallsSettleCorrectly() async throws {
            let voices = ConversationRecorder()
            voices.script = { _, service in
                service.enqueueCreate(Fixtures.resumeResult(runtimeID: "rt-a", storedID: "stored-a"))
            }
            let controller = voices.make(connection: makeUndialedConnection(), profile: nil)
            var reported: [Bool] = []
            controller.onMuteChanged = { reported.append($0) }
            await controller.begin(mode: .create(cwd: nil, title: nil))
            controller.setMuted(true)
            controller.setMuted(true)
            #expect(await eventually { controller.voiceState.muted })
            try await Task.sleep(for: .milliseconds(150))
            #expect(controller.voiceState.muted)
            #expect(reported == [true])
            controller.setMuted(true)
            controller.setMuted(false)
            #expect(await eventually { !controller.voiceState.muted })
            try await Task.sleep(for: .milliseconds(150))
            #expect(!controller.voiceState.muted)
            await controller.teardown()
        }

        @Test func setupErrorIsReported() async {
            let voices = ConversationRecorder()
            // No scripted create answer: ScriptedSessionService throws, so
            // the open fails.
            let controller = voices.make(connection: makeUndialedConnection(), profile: nil)
            var errors: [String] = []
            controller.onSetupError = { errors.append($0) }
            await controller.begin(mode: .create(cwd: nil, title: nil))
            #expect(errors.count == 1)
            await controller.teardown()
        }

        @Test func callUnavailableShowsNotice() {
            let controller = makeController(service: ScriptedSessionService())
            controller.noteCallUnavailable()
            #expect(controller.notice == ConversationController.callUnavailableNotice)
        }
    }
}

/// A one-shot gate a test opens by hand.
@MainActor
final class CallHooksGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
