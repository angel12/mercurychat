import Foundation
import MercuryKit
@testable import MercuryVoiceEngine
import Testing

/// Barge-in only ever cuts short a turn that is this conversation's own
/// (final review item 1). While a voice prompt waits behind another app's
/// turn the tracker is busy with that turn's gate, and the engine arms its
/// barge monitor whenever the tracker is busy: a barge then would send
/// `session.interrupt` and stop the other app's turn.
///
/// These drive the real engine (`begin()` → `startVoiceLoop()`) with a
/// scripted microphone, transcriber and barge monitor, so they join the
/// shared-meter parent.
extension SharedMeterTests {
    @MainActor
    @Suite("Voice barge-in gate")
    struct VoiceBargeGateTests {

        private struct Rig {
            let controller: ConversationController
            let recorder: TurnRecorder
            let barge: TrippableBargeMonitor
            let log: BargeLog
        }

        /// One voice conversation on an authority whose spoken submits get
        /// `receipts[i]` (the last one repeats) and whose text submits get
        /// `textReceipt`.
        private func rig(
            receipts: [PromptSubmission], textReceipt: PromptSubmission? = nil
        ) async throws -> Rig {
            let service = ScriptedSessionService()
            service.setAuthority(true)
            service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
            let recorder = TurnRecorder()
            let barge = TrippableBargeMonitor()
            let log = BargeLog()
            let controller = ConversationController(
                connection: makeUndialedConnection(), profile: nil,
                sessionService: service, speech: RecordingSpeech(),
                audio: ConversationController.AudioStack(
                    recorder: recorder, bargeMonitor: barge,
                    transcriber: FixedTranscriber(text: "hello there"),
                    microphone: AlwaysGrantedMicrophone()),
                submitPrompt: { _, text, interrupted, _ in
                    let index = await log.submitted(text: text, interrupted: interrupted)
                    if text == "typed", let textReceipt { return textReceipt }
                    return receipts[min(index, receipts.count - 1)]
                },
                retryDelay: { _ in },
                interruptSession: { sid in await log.interrupted(sid) },
                bargeInEnabled: { true })
            await controller.begin(mode: .create(cwd: nil, title: nil))
            try #require(await eventually { recorder.isListening })
            return Rig(controller: controller, recorder: recorder, barge: barge, log: log)
        }

        /// Speak one turn: the VAD closes it and the transcript goes out.
        private func speak(_ rig: Rig, submits: Int) async throws {
            rig.recorder.endTurn()
            try #require(await eventuallyAsync { await rig.log.submits.count == submits })
        }

        private func eventuallyAsync(
            within seconds: TimeInterval = 10, _ condition: () async -> Bool
        ) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return await condition()
        }

        /// The engine arms the monitor from its drive loop after the submit
        /// returns; give it that hop before asserting it stayed disarmed.
        private func settle(_ rig: Rig) async {
            _ = await eventually(within: 0.5) { rig.barge.startCalls > 0 }
        }

        @Test func aQueuedPromptNeverBargesIntoTheTurnAheadOfIt() async throws {
            let rig = try await rig(receipts: [
                PromptSubmission(status: "queued", admissionID: "a1")
            ])
            try await speak(rig, submits: 1)
            #expect(rig.controller.isWaitingForTurn)
            await settle(rig)

            #expect(rig.barge.startCalls == 0, "barge-in armed behind another app's turn")
            // A barge, had the monitor armed anyway, must not interrupt.
            await rig.barge.trip(with: nil)
            try? await Task.sleep(for: .milliseconds(100))
            #expect(await rig.log.interrupts.isEmpty, "session.interrupt stopped another app's turn")
            await rig.controller.teardown()
        }

        /// Our own turn is still ours to barge into.
        @Test func bargingIntoOurOwnTurnStillInterruptsIt() async throws {
            let rig = try await rig(receipts: [
                PromptSubmission(status: "streaming", admissionID: "a1")
            ])
            try await speak(rig, submits: 1)
            try #require(await eventually { rig.barge.startCalls == 1 })

            await rig.barge.trip(with: TurnRecorder.utterance)
            // The interrupted turn ends; the capture goes out behind it.
            try #require(await eventuallyAsync { await rig.log.interrupts.count == 1 })
            rig.controller.handle(
                event: GatewayEvent(
                    type: GatewayEvent.Kind.messageComplete, sessionID: "runtime",
                    payload: .object(["text": .string("cut short")])))
            try #require(await eventuallyAsync { await rig.log.submits.count == 2 })
            #expect(await rig.log.interrupts == ["runtime"])
            #expect(await rig.log.submits.last?.interrupted == true)
            await rig.controller.teardown()
        }

        /// Armed during our turn, then a typed prompt queues behind another
        /// app's turn: a barge now stops nothing on the server, and the
        /// captured words do not go out as an interruption.
        @Test func aBargeAfterOurPromptQueuedIsNotAnInterrupt() async throws {
            let rig = try await rig(
                receipts: [PromptSubmission(status: "streaming", admissionID: "a1")],
                textReceipt: PromptSubmission(status: "queued", admissionID: "a2"))
            try await speak(rig, submits: 1)
            try #require(await eventually { rig.barge.startCalls == 1 })
            rig.controller.submitTextPrompt("typed")
            await rig.controller.textSubmissionTask?.value
            try #require(rig.controller.isWaitingForTurn)

            await rig.barge.trip(with: TurnRecorder.utterance)
            // The tracker stays busy on our queued gate, so the capture goes
            // out at the engine's interrupt-settle deadline (~5 s).
            try #require(await eventuallyAsync { await rig.log.submits.count == 3 })
            #expect(await rig.log.interrupts.isEmpty, "session.interrupt stopped another app's turn")
            #expect(await rig.log.submits.last?.interrupted == false)
            await rig.controller.teardown()
        }
    }
}

/// Submits and interrupts the controller sent, in order.
private actor BargeLog {
    private(set) var submits: [(text: String, interrupted: Bool)] = []
    private(set) var interrupts: [String] = []

    /// Returns the zero-based index of this spoken submit (typed ones
    /// count too; the rig only reads it for spoken receipts).
    func submitted(text: String, interrupted: Bool) -> Int {
        submits.append((text, interrupted))
        return submits.filter { $0.text != "typed" }.count - 1
    }

    func interrupted(_ sessionID: String) { interrupts.append(sessionID) }
}

/// A microphone the test closes: `endTurn()` is the VAD's auto-stop, and
/// the recording heard speech.
private final class TurnRecorder: VoiceRecording, @unchecked Sendable {
    static let utterance = RecordedUtterance(
        audio: Data([0, 1, 2, 3]), mimeType: "audio/wav", duration: .seconds(1),
        heardSpeech: true)

    private let lock = NSLock()
    private var autoStop: (@Sendable () -> Void)?

    var isListening: Bool { lock.withLock { autoStop != nil } }

    func start(vad: VADParameters, onAutoStop: @escaping @Sendable () -> Void) async throws {
        lock.withLock { autoStop = onAutoStop }
    }

    func endTurn() {
        let stop = lock.withLock {
            defer { autoStop = nil }
            return autoStop
        }
        stop?()
    }

    func stop() async -> RecordedUtterance? { Self.utterance }

    func cancel() async { lock.withLock { autoStop = nil } }
}

/// A barge monitor the test trips: `trip(with:)` is the user talking over
/// the reply, then the captured utterance (nil: nothing usable).
private final class TrippableBargeMonitor: BargeMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _startCalls = 0
    private var _capturing = false
    private var onSpeech: (@Sendable () -> Void)?
    private var onUtterance: (@Sendable (RecordedUtterance?) -> Void)?

    var startCalls: Int { lock.withLock { _startCalls } }
    var isCapturing: Bool { lock.withLock { _capturing } }

    func start(
        isPlaying: @escaping @Sendable () async -> Bool,
        onSpeech: @escaping @Sendable () -> Void,
        onUtterance: @escaping @Sendable (RecordedUtterance?) -> Void
    ) async throws {
        lock.withLock {
            _startCalls += 1
            self.onSpeech = onSpeech
            self.onUtterance = onUtterance
        }
    }

    func trip(with utterance: RecordedUtterance?) async {
        let (speech, captured) = lock.withLock {
            _capturing = onSpeech != nil
            return (onSpeech, onUtterance)
        }
        speech?()
        // The engine handles the trip on its actor before the capture ends.
        try? await Task.sleep(for: .milliseconds(50))
        lock.withLock {
            _capturing = false
            onSpeech = nil
            onUtterance = nil
        }
        captured?(utterance)
    }

    func stop() async {
        lock.withLock {
            _capturing = false
            onSpeech = nil
            onUtterance = nil
        }
    }

    func setSuspended(_ suspended: Bool) async {}
}

private struct FixedTranscriber: Transcribing {
    let text: String
    func transcribe(_ utterance: RecordedUtterance) async throws -> String { text }
}
