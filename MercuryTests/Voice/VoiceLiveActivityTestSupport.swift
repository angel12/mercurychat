import Foundation
import Observation

struct FakeLiveActivityStartError: Error {}

@MainActor
final class FakeLiveActivitySystem: VoiceLiveActivitySystem {
    private(set) var starts: [(id: String, startedAt: Date, content: VoiceActivityContent)] = []
    private(set) var updates: [(id: String, content: VoiceActivityContent)] = []
    private(set) var ends: [String] = []
    private(set) var endAllCount = 0
    var startError: (any Error)?

    func start(startedAt: Date, content: VoiceActivityContent) throws -> String {
        if let startError { throw startError }
        let id = "activity-\(starts.count)"
        starts.append((id, startedAt, content))
        return id
    }
    func update(_ id: String, content: VoiceActivityContent) async { updates.append((id, content)) }
    func end(_ id: String) async { ends.append(id) }
    func endAll() async { endAllCount += 1 }
}

/// A stand-in for the host: an observable content value.
@MainActor @Observable
final class ObservableActivitySource {
    var content: VoiceActivityContent?
    init(_ content: VoiceActivityContent?) { self.content = content }
}

extension VoiceActivityContent {
    static func sample(
        _ phase: VoiceActivityPhase = .listening, title: String = "Voice conversation",
        muted: Bool = false
    ) -> VoiceActivityContent {
        VoiceActivityContent(title: title, phase: phase, muted: muted)
    }
}
