import Foundation
@testable import Kaset

final class MockEqualizerAudioEngine: EqualizerAudioEngineProtocol {
    var startResult: Result<Void, EqualizerAudioEngine.StartFailure>
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var lastAppliedSettings: EQSettings?
    private var running = false

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
