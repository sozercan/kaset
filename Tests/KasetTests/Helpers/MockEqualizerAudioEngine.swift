import Foundation
@testable import Kaset

// MARK: - MockEqualizerAudioEngine

/// In-memory stub of `EqualizerAudioEngineProtocol` so
/// `EqualizerServiceTests` can exercise the service's state machine
/// without touching Core Audio. Lives in `Helpers/` because multiple
/// suites may grow to need it.
final class MockEqualizerAudioEngine: EqualizerAudioEngineProtocol {
    var startResult: Result<Void, EqualizerAudioEngine.StartFailure>
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var lastAppliedSettings: EQSettings?
    private var running = false

    /// Tests can flip this to simulate a tap that succeeds at start time
    /// but never delivers audio (the silence-detection path).
    var hasObservedAudio: Bool = true

    init(startResult: Result<Void, EqualizerAudioEngine.StartFailure> = .success(())) {
        self.startResult = startResult
    }

    var isRunning: Bool {
        self.running
    }

    func start() -> Result<Void, EqualizerAudioEngine.StartFailure> {
        self.startCallCount += 1
        if case .success = self.startResult {
            self.running = true
        }
        return self.startResult
    }

    func stop() {
        self.stopCallCount += 1
        self.running = false
    }

    func apply(settings: EQSettings) {
        self.lastAppliedSettings = settings
    }
}
