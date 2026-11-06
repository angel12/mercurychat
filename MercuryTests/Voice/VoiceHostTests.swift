import Foundation
import MercuryKit
import MercuryVoiceEngine
import Testing

/// The Voice tab's app-wide conversation (spec §1–§2): `AppModel` owns at
/// most one `VoiceConversationHost`, feeds it Chat's update pump, and lets it
/// join Chat's multi-window coordination (#112) — neither side closes a
/// runtime the other holds, and a server request answered on one side is
/// withdrawn on the other.
///
/// The connection is real (`HermesTestServer`, scripted like
/// `MultiWindowChatTests`), so chats resume over the wire and gateway events
/// arrive through the real pump. Voice controllers come from
/// `ConversationRecorder`: their session RPCs are scripted per launch and
/// their audio is silent. Phases the test server cannot produce on demand
/// (`.unreachable`) go through `AppModel.handleUpdateForTesting`.
///
/// Also carries Voice's R25 ownership/race scenarios
/// (`R25ConversationOwnershipTests`), re-pointed at Chat's host. Joins the
/// shared-meter parent: every successful voice `begin` installs the
/// process-global level meter.
extension SharedMeterTests {
    @MainActor
    @Suite("Voice conversation host")
    struct VoiceHostTests {

        // MARK: Harness

        private struct Harness {
            let model: AppModel
            let server: HermesTestServer
            let voices: ConversationRecorder
            let cleanup: () -> Void
        }

        /// Every voice launch `i` answers its open with runtime `rt-<x>` and
        /// stored `stored-<x>`, where `<x>` comes from `ids[i]` (default
        /// `v<i>`). The ids line up with `MultiWindowChatTests.Script`, so a
        /// chat resuming `stored-a` lands on the voice launch's `rt-a`.
        private func connected(
            ids: [Int: String] = [:], gates: [Int: CallGate] = [:]
        ) async throws -> Harness {
            let script = MultiWindowChatTests.Script()
            let server = try await HermesTestServer.start(
                rpc: { method, params in script.respond(method: method, params: params) }
            ) { request in
                switch (request.method, request.path) {
                case ("GET", "/api/status"):
                    return TestHTTPResponse(200, #"{"auth_required": false}"#)
                default:
                    return TestHTTPResponse(200, #"{"messages": []}"#)
                }
            }
            let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
            let store = KeychainTokenStore(service: "com.mercury.tokens.tests")
            let model = AppModel(tokenStore: store)
            let voices = ConversationRecorder()
            voices.script = { index, service in
                let id = ids[index] ?? "v\(index)"
                let answer = Fixtures.resumeResult(
                    runtimeID: "rt-\(id)", storedID: "stored-\(id)")
                service.enqueueCreate(answer)
                service.enqueueResume(answer)
                if let gate = gates[index] {
                    service.createGate = gate
                    service.resumeGate = gate
                }
            }
            model.makeVoiceController = { voices.make(connection: $0, profile: $1) }
            await model.connect(endpoint: endpoint, credentials: nil)
            let ready = await eventually {
                if case .ready = model.phase { return true }
                return false
            }
            try #require(ready)
            return Harness(
                model: model, server: server, voices: voices,
                cleanup: {
                    server.stop()
                    try? store.deleteToken(for: endpoint)
                })
        }

        /// Join every launch before the shared parent admits the next test,
        /// as R25's `finish` does.
        private func finish(_ harness: Harness) async {
            await harness.model.pendingVoiceTeardown?.value
            harness.model.disconnect()
            await harness.model.pendingVoiceTeardown?.value
            for launch in harness.voices.launches {
                await launch.controller.teardown()
            }
            #expect(ConversationController.levelMeterOwner == nil)
            harness.cleanup()
        }

        private func session(_ id: String, profile: String? = nil)
            -> VoiceConversationHost.Target
        {
            .session(storedID: "stored-\(id)", title: nil, profile: profile)
        }

        private func newSession(_ cwd: String) -> VoiceConversationHost.Target {
            .new(cwd: cwd, profile: nil, request: UUID())
        }

        private func resumedChat(_ model: AppModel, _ storedID: String) async throws
            -> ChatController
        {
            let chat = try #require(model.openChat(profile: nil))
            let summary = try #require(
                SessionSummary(json: .object(["session_id": .string(storedID)])))
            await chat.begin(.resume(summary))
            try #require(chat.runtimeID != nil)
            return chat
        }

        private func closes(_ server: HermesTestServer, _ runtimeID: String) -> Int {
            server.rpcRequests.filter {
                $0.method == "session.close"
                    && $0.params["session_id"]?.stringValue == runtimeID
            }.count
        }

        // MARK: One conversation, app-wide

        /// R25 `launchingOverASettledConversationTearsTheOldOneDown`.
        @Test func startVoiceHoldsOneConversationAndSwitchingEndsTheOld() async throws {
            let h = try await connected(ids: [0: "a", 1: "b"])
            let model = h.model

            await model.startVoice(session("a"))
            let a = h.voices.launches[0]
            #expect(model.voiceConversation?.controller === a.controller)
            #expect(a.recorder.startCalls == 1)

            await model.startVoice(session("b"))
            await model.pendingVoiceTeardown?.value
            let b = h.voices.launches[1]

            #expect(model.voiceConversation?.target == session("b"))
            #expect(model.voiceConversation?.controller === b.controller)
            #expect(a.service.closedIDs == ["rt-a"])
            #expect(b.service.closedIDs.isEmpty)
            #expect(b.recorder.startCalls == 1)
            #expect(b.service.resumedIDs == ["stored-b"])

            await finish(h)
        }

        @Test func startingTheRunningTargetAgainKeepsIt() async throws {
            let h = try await connected(ids: [0: "a"])
            let model = h.model

            await model.startVoice(session("a"))
            let host = try #require(model.voiceConversation)
            await model.startVoice(session("a"))

            #expect(model.voiceConversation === host)
            #expect(h.voices.launches.count == 1)
            #expect(h.voices.launches[0].service.resumedIDs == ["stored-a"])
            #expect(h.voices.launches[0].service.closedIDs.isEmpty)

            await finish(h)
        }

        /// A new-session request is its own target: a second "New session"
        /// starts a second conversation even in the same cwd.
        @Test func eachNewSessionRequestIsADistinctTarget() async throws {
            let h = try await connected()
            await h.model.startVoice(newSession("/one"))
            await h.model.startVoice(newSession("/one"))
            await h.model.pendingVoiceTeardown?.value
            #expect(h.voices.launches.count == 2)
            #expect(h.voices.launches[0].service.closedIDs == ["rt-v0"])
            await finish(h)
        }

        /// R25 `aSecondCreateSupersedesTheFirstInFlightLaunch`, and the
        /// brief's `aLateBeginAfterASwitchIsTornDown`.
        @Test func aLateBeginAfterASwitchIsTornDown() async throws {
            let firstOpen = CallGate()
            let secondOpen = CallGate()
            let h = try await connected(gates: [0: firstOpen, 1: secondOpen])
            let model = h.model

            let first = Task { await model.startVoice(newSession("/one")) }
            await firstOpen.waitUntilEntered()
            #expect(h.voices.launches.count == 1)
            #expect(model.voiceConversation?.controller === h.voices.launches[0].controller)

            let second = Task { await model.startVoice(newSession("/two")) }
            await secondOpen.waitUntilEntered()

            // Ownership moved before the replacement even opened its session.
            #expect(h.voices.launches.count == 2)
            #expect(model.voiceConversation?.controller === h.voices.launches[1].controller)
            #expect(h.voices.launches[0].service.createdCWDs == ["/one"])
            #expect(h.voices.launches[1].service.createdCWDs == ["/two"])

            await secondOpen.release()
            await second.value
            #expect(model.voiceConversation?.controller === h.voices.launches[1].controller)

            await firstOpen.release()
            await first.value

            // The superseded launch never armed the mic, closed the session it
            // was handed, and did not take ownership back.
            #expect(h.voices.launches[0].recorder.startCalls == 0)
            #expect(h.voices.launches[0].bargeMonitor.startCalls == 0)
            #expect(h.voices.launches[0].service.closedIDs == ["rt-v0"])
            #expect(model.voiceConversation?.controller === h.voices.launches[1].controller)
            #expect(h.voices.launches[1].recorder.startCalls == 1)
            #expect(h.voices.launches[1].service.closedIDs.isEmpty)

            await finish(h)
        }

        /// R25 `aResumeSupersedesAnInFlightCreate`: the other entry point,
        /// with the target's own profile.
        @Test func aResumeSupersedesAnInFlightCreate() async throws {
            let createOpen = CallGate()
            let resumeOpen = CallGate()
            let h = try await connected(ids: [1: "abc"], gates: [0: createOpen, 1: resumeOpen])
            let model = h.model

            let create = Task { await model.startVoice(newSession("/one")) }
            await createOpen.waitUntilEntered()

            let resume = Task { await model.startVoice(session("abc", profile: "work")) }
            await resumeOpen.waitUntilEntered()

            #expect(model.voiceConversation?.controller === h.voices.launches[1].controller)
            #expect(h.voices.launches[1].profile == "work")
            #expect(h.voices.launches[1].service.resumedIDs == ["stored-abc"])

            await resumeOpen.release()
            await resume.value
            await createOpen.release()
            await create.value

            #expect(h.voices.launches[0].recorder.startCalls == 0)
            #expect(h.voices.launches[0].service.closedIDs == ["rt-v0"])
            #expect(model.voiceConversation?.controller === h.voices.launches[1].controller)
            #expect(h.voices.launches[1].recorder.startCalls == 1)

            await finish(h)
        }

        // MARK: Ending

        /// R25 `aSingleLaunchOwnsTheConversationAndTearsDownCleanly`'s end half.
        @Test func endVoiceTearsDownAndClears() async throws {
            let h = try await connected(ids: [0: "a"])
            let model = h.model

            await model.startVoice(session("a"))
            let launch = h.voices.launches[0]
            #expect(launch.controller.setupError == nil)
            #expect(launch.recorder.startCalls == 1)

            model.endVoice()
            #expect(model.voiceConversation == nil)
            await model.pendingVoiceTeardown?.value
            #expect(launch.service.closedIDs == ["rt-a"])
            #expect(launch.recorder.cancelCalls >= 1)

            await finish(h)
        }

        /// R25 `endingDuringAnInFlightLaunchLeavesNothingRunning`.
        @Test func endingDuringAnInFlightLaunchLeavesNothingRunning() async throws {
            let open = CallGate()
            let h = try await connected(gates: [0: open])
            let model = h.model

            let launch = Task { await model.startVoice(newSession("/one")) }
            await open.waitUntilEntered()

            model.endVoice()
            #expect(model.voiceConversation == nil)

            await open.release()
            await launch.value
            await model.pendingVoiceTeardown?.value

            #expect(model.voiceConversation == nil)
            #expect(h.voices.launches[0].recorder.startCalls == 0)
            #expect(h.voices.launches[0].service.closedIDs == ["rt-v0"])

            await finish(h)
        }

        @Test func stopWordEndsTheConversationWithoutTheView() async throws {
            let h = try await connected(ids: [0: "a"])
            await h.model.startVoice(session("a"))
            let controller = try #require(h.model.voiceConversation?.controller)

            controller.onStopWord?()

            #expect(h.model.voiceConversation == nil)
            await h.model.pendingVoiceTeardown?.value
            #expect(h.voices.launches[0].service.closedIDs == ["rt-a"])
            await finish(h)
        }

        /// A superseded controller's late stop word must not end its
        /// replacement.
        @Test func aSupersededControllersStopWordLeavesTheReplacement() async throws {
            let h = try await connected(ids: [0: "a", 1: "b"])
            await h.model.startVoice(session("a"))
            let old = h.voices.launches[0].controller
            await h.model.startVoice(session("b"))

            old.onStopWord?()

            #expect(h.model.voiceConversation?.controller === h.voices.launches[1].controller)
            await finish(h)
        }

        // MARK: Chat's pump

        @Test func eventsReachVoiceAndChats() async throws {
            let h = try await connected(ids: [0: "a"])
            let chat = try await resumedChat(h.model, "stored-a")
            await h.model.startVoice(session("a"))
            let voice = h.voices.launches[0].controller

            h.server.pushEvent(
                "session.title", sessionID: "rt-a", payload: ["title": "Spoken"])

            #expect(await eventually { chat.store.title == "Spoken" })
            #expect(await eventually { voice.sessionTitle == "Spoken" })

            await finish(h)
        }

        @Test func connectionPhasesReachVoice() async throws {
            let h = try await connected(ids: [0: "a"])
            await h.model.startVoice(session("a"))
            let voice = h.voices.launches[0].controller
            #expect(voice.connectionHealthy)

            await h.model.handleUpdateForTesting(.phase(.disconnected(reason: nil)))
            #expect(!voice.connectionHealthy)
            await h.model.handleUpdateForTesting(.phase(.ready(isReconnect: false)))
            #expect(voice.connectionHealthy)
            await h.model.handleUpdateForTesting(.phase(.connecting(attempt: 1)))
            #expect(!voice.connectionHealthy)

            await finish(h)
        }

        /// R25 `aSingleLaunchOwnsTheConversationAndTearsDownCleanly`'s
        /// disconnect half.
        @Test func disconnectEndsVoice() async throws {
            let h = try await connected(ids: [0: "a"])
            await h.model.startVoice(session("a"))
            let launch = h.voices.launches[0]

            h.model.disconnect()
            #expect(h.model.voiceConversation == nil)
            await h.model.pendingVoiceTeardown?.value
            #expect(launch.service.closedIDs == ["rt-a"])
            #expect(launch.recorder.cancelCalls >= 1)

            await finish(h)
        }

        /// R25 `disconnectingDuringAnInFlightLaunchLeavesNothingRunning`.
        @Test func disconnectingDuringAnInFlightLaunchLeavesNothingRunning() async throws {
            let open = CallGate()
            let h = try await connected(gates: [0: open])
            let model = h.model

            let launch = Task { await model.startVoice(newSession("/one")) }
            await open.waitUntilEntered()

            model.disconnect()
            #expect(model.voiceConversation == nil)
            #expect(model.connection == nil)

            await open.release()
            await launch.value
            await model.pendingVoiceTeardown?.value

            #expect(model.voiceConversation == nil)
            #expect(h.voices.launches[0].recorder.startCalls == 0)
            #expect(h.voices.launches[0].service.closedIDs == ["rt-v0"])

            await finish(h)
        }

        @Test func unreachableEndsVoice() async throws {
            let h = try await connected(ids: [0: "a"])
            await h.model.startVoice(session("a"))

            await h.model.handleUpdateForTesting(.phase(.unreachable(reason: "gone")))

            #expect(h.model.voiceConversation == nil)
            await h.model.pendingVoiceTeardown?.value
            #expect(h.voices.launches[0].service.closedIDs == ["rt-a"])
            await finish(h)
        }

        @Test func refusedEndsVoice() async throws {
            let h = try await connected(ids: [0: "a"])
            await h.model.startVoice(session("a"))

            await h.model.handleUpdateForTesting(.phase(.refused(reason: nil)))

            #expect(h.model.voiceConversation == nil)
            await finish(h)
        }

        // MARK: Shared runtimes (#112)

        @Test func voiceTeardownSkipsCloseWhenAChatHoldsTheRuntime() async throws {
            let h = try await connected(ids: [0: "a"])
            let chat = try await resumedChat(h.model, "stored-a")
            #expect(chat.runtimeID == "rt-a")
            await h.model.startVoice(session("a"))
            let launch = h.voices.launches[0]

            h.model.endVoice()
            await h.model.pendingVoiceTeardown?.value

            #expect(launch.service.closedIDs.isEmpty, "voice closed the chat's runtime")
            // Leases are still released.
            #expect(launch.service.sttLeaseCalls.contains { !$0.active })
            await finish(h)
        }

        @Test func chatTeardownSkipsCloseWhenVoiceHoldsTheRuntime() async throws {
            let h = try await connected(ids: [0: "a"])
            await h.model.startVoice(session("a"))
            let chat = try await resumedChat(h.model, "stored-a")
            #expect(chat.runtimeID == "rt-a")

            h.model.closeChat(chat)
            try await Task.sleep(for: .milliseconds(500))
            #expect(closes(h.server, "rt-a") == 0, "the chat closed voice's runtime")

            // Without voice holding it, the chat's close goes out as before.
            let other = try await resumedChat(h.model, "stored-b")
            h.model.closeChat(other)
            #expect(await eventually(within: 3) { closes(h.server, "rt-b") == 1 })
            await finish(h)
        }

        /// Voice still opening the stored session counts as holding it.
        @Test func aVoiceResumeInFlightKeepsTheChatsRuntimeOpen() async throws {
            let open = CallGate()
            let h = try await connected(ids: [0: "a"], gates: [0: open])
            let chat = try await resumedChat(h.model, "stored-a")

            let launch = Task { await h.model.startVoice(session("a")) }
            await open.waitUntilEntered()

            h.model.closeChat(chat)
            try await Task.sleep(for: .milliseconds(500))
            #expect(closes(h.server, "rt-a") == 0, "the chat closed the runtime voice is resuming")

            await open.release()
            await launch.value
            await finish(h)
        }

        @Test func voiceSettlingARequestWithdrawsItFromChatsOnTheRuntime() async throws {
            let h = try await connected(ids: [0: "a"])
            let chat = try await resumedChat(h.model, "stored-a")
            let elsewhere = try await resumedChat(h.model, "stored-b")
            await h.model.startVoice(session("a"))
            let voice = h.voices.launches[0].controller

            h.server.push([
                "jsonrpc": "2.0", "id": "srq-aaaaaaaaaaa1", "method": "approval",
                "params": ["session_id": "rt-a", "request_id": "ap1", "command": "rm -rf build"],
            ])
            h.server.push([
                "jsonrpc": "2.0", "id": "srq-bbbbbbbbbbb1", "method": "approval",
                "params": ["session_id": "rt-b", "request_id": "ap2", "command": "ls"],
            ])
            #expect(
                await eventually {
                    chat.store.pendingApproval != nil && voice.approval != nil
                        && elsewhere.store.pendingApproval != nil
                })
            #expect(voice.approval?.serverRequestID == "srq-aaaaaaaaaaa1")

            voice.respondApproval(choice: "once")
            await voice.awaitPromptResponse()

            #expect(voice.approval == nil)
            #expect(await eventually { chat.store.pendingApproval == nil }, "the chat kept the card")
            #expect(elsewhere.store.pendingApproval?.serverRequestID == "srq-bbbbbbbbbbb1")
            await finish(h)
        }

        @Test func chatSettlingARequestWithdrawsItFromVoice() async throws {
            let h = try await connected(ids: [0: "a"])
            let chat = try await resumedChat(h.model, "stored-a")
            await h.model.startVoice(session("a"))
            let voice = h.voices.launches[0].controller

            h.server.push([
                "jsonrpc": "2.0", "id": "srq-aaaaaaaaaaa1", "method": "approval",
                "params": ["session_id": "rt-a", "request_id": "ap1", "command": "rm -rf build"],
            ])
            #expect(await eventually { chat.store.pendingApproval != nil && voice.approval != nil })

            let approval = try #require(chat.store.pendingApproval)
            #expect(await chat.respondApproval(approval, choice: "once"))

            #expect(voice.approval == nil, "voice kept the answered prompt")
            #expect(h.voices.launches[0].service.promptResponses.isEmpty)
            await finish(h)
        }

        // MARK: Shared level meter (R25)

        /// R25 `delayedCleanupCannotTakeTheLevelMeterFromTheReplacement` and
        /// `anotherFixtureCanOwnTheMeterWhenR25CleanupReturns`, through the
        /// host: a superseded controller's late teardown leaves the
        /// replacement's meter alone.
        @Test func delayedCleanupCannotTakeTheLevelMeterFromTheReplacement() async throws {
            let h = try await connected(ids: [0: "a", 1: "b"])
            await h.model.startVoice(session("a"))
            let superseded = h.voices.launches[0].controller
            #expect(ConversationController.levelMeterOwner === superseded)

            await h.model.startVoice(session("b"))
            await h.model.pendingVoiceTeardown?.value
            let replacement = h.voices.launches[1].controller
            #expect(ConversationController.levelMeterOwner === replacement)

            await superseded.teardown()
            #expect(ConversationController.levelMeterOwner === replacement)

            h.model.endVoice()
            await h.model.pendingVoiceTeardown?.value
            #expect(ConversationController.levelMeterOwner == nil)
            await finish(h)
        }
    }
}
