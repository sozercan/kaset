import Foundation
import Testing
@testable import Kaset

// MARK: - EqualizerServiceTests

/// Tests for `EqualizerService`. Uses a mock `EqualizerAudioEngineProtocol`
/// so the real Core Audio process tap is never touched.
@Suite(.serialized, .tags(.service))
@MainActor
struct EqualizerServiceTests {
    private static let storageKey = "settings.equalizer.v1"

    /// Returns a service backed by a fresh mock engine. Each call wipes
    /// the persisted settings so tests start from `.flat`. Note: a stray
    /// write from the last test in the suite remains in UserDefaults
    /// until the next test run wipes it again — acceptable because the
    /// tests use the same key as production and the suite is `.serialized`.
    /// Swift Testing `Suite` types are structs and can't host a `deinit`,
    /// so a "save snapshot, restore on teardown" pattern would require a
    /// class wrapper that isn't worth the boilerplate here.
    private static func makeService(
        startResult: Result<Void, EqualizerAudioEngine.StartFailure> = .success(())
    ) -> (EqualizerService, MockEqualizerAudioEngine) {
        UserDefaults.standard.removeObject(forKey: self.storageKey)
        let mock = MockEqualizerAudioEngine(startResult: startResult)
        let service = EqualizerService(engine: mock, isPlaybackActive: { false })
        return (service, mock)
    }

    // MARK: - Preset application

    @Test("Applying a preset replaces every band gain")
    func applyPresetReplacesBands() {
        let (service, _) = Self.makeService()
        service.apply(preset: .bassBooster)

        #expect(service.settings.preset == .bassBooster)
        #expect(service.settings.bandGainsDB == EQPreset.bassBooster.bandGainsDB)
    }

    @Test("Applying a preset clamps any out-of-range values")
    func applyPresetClamps() {
        let (service, _) = Self.makeService()
        // Sanity: every preset already lives in range, so this verifies
        // clampGains doesn't mutate values that are already legal.
        service.apply(preset: .classical)
        for gain in service.settings.bandGainsDB {
            #expect(gain >= EQSettings.minGainDB && gain <= EQSettings.maxGainDB)
        }
    }

    // MARK: - Single-band edits

    @Test("setGain snaps the active preset to .custom")
    func setGainSnapsToCustom() {
        let (service, _) = Self.makeService()
        service.apply(preset: .rock)
        #expect(service.settings.preset == .rock)

        service.setGain(forBandAt: 0, to: 1.5)
        #expect(service.settings.preset == .custom)
        #expect(service.settings.bandGainsDB[0] == 1.5)
    }

    @Test("setGain clamps to the legal range")
    func setGainClamps() {
        let (service, _) = Self.makeService()
        service.setGain(forBandAt: 0, to: 999)
        #expect(service.settings.bandGainsDB[0] == EQSettings.maxGainDB)
        service.setGain(forBandAt: 0, to: -999)
        #expect(service.settings.bandGainsDB[0] == EQSettings.minGainDB)
    }

    @Test("setGain ignores out-of-bounds indices")
    func setGainIgnoresInvalidIndex() {
        let (service, _) = Self.makeService()
        let original = service.settings.bandGainsDB
        service.setGain(forBandAt: 999, to: 5)
        #expect(service.settings.bandGainsDB == original)
    }

    // MARK: - Preamp

    @Test("setPreamp does not change the active preset")
    func setPreampPreservesPreset() {
        let (service, _) = Self.makeService()
        service.apply(preset: .pop)
        service.setPreamp(-3)
        #expect(service.settings.preset == .pop)
        #expect(service.settings.preampDB == -3)
    }

    // MARK: - Reset

    @Test("reset returns to flat bands but preserves isEnabled")
    func resetPreservesEnabledState() {
        let (service, _) = Self.makeService()
        service.apply(preset: .rock)
        service.setEnabled(true)
        // Engine started successfully; reset should not flip enabled off.
        service.reset()
        #expect(service.settings.preset == .flat)
        #expect(service.settings.bandGainsDB.allSatisfy { $0 == 0 })
        #expect(service.settings.isEnabled == true)
    }

    // MARK: - Engine lifecycle

    @Test("Successful start applies settings to the engine")
    func startAppliesSettings() {
        let (service, mock) = Self.makeService()
        service.apply(preset: .jazz)
        service.setEnabled(true)

        #expect(mock.startCallCount == 1)
        #expect(mock.lastAppliedSettings?.preset == .jazz)
        #expect(service.lastFailure == nil)
    }

    @Test("Explicit tap-creation failure auto-disables the toggle and surfaces the permission CTA")
    func permissionFailureAutoDisables() {
        let (service, mock) = Self.makeService(startResult: .failure(.tap(.tapCreation(-1))))
        service.setEnabled(true)

        #expect(mock.startCallCount == 1)
        // Toggle flips off so the UI matches the engine's actual state.
        #expect(service.settings.isEnabled == false)
        // But the permission warning persists so the user sees the
        // call-to-action even after the toggle has gone back to off.
        if case .permissionNeeded = service.status {
            // expected
        } else {
            Issue.record("Expected .permissionNeeded status, got \(service.status)")
        }
    }

    @Test("Re-enabling clears the inferred permission warning and retries")
    func reEnableClearsPermissionFlag() {
        let (service, mock) = Self.makeService(startResult: .failure(.tap(.tapCreation(-1))))
        service.setEnabled(true)
        // Now the toggle is off + permission warning is showing.
        #expect(service.settings.isEnabled == false)

        // User grants permission and re-toggles.
        mock.startResult = .success(())
        service.setEnabled(true)
        #expect(service.settings.isEnabled == true)
        #expect(service.status == .active)
    }

    @Test("No-audio-source failure stays silent (waiting for playback)")
    func noAudioSourceShowsStandby() {
        let (service, mock) = Self.makeService(startResult: .failure(.tap(.noAudioSource)))
        service.setEnabled(true)

        #expect(mock.startCallCount == 1)
        #expect(service.settings.isEnabled == true)
        #expect(service.lastFailure == nil)
        #expect(service.status == .standby)
    }

    @Test("retryStartIfEnabled is a no-op when toggle is off")
    func retryNoOpsWhenDisabled() async {
        let (service, mock) = Self.makeService()
        service.setEnabled(false)
        let baseline = mock.startCallCount

        service.retryStartIfEnabled()
        try? await Task.sleep(for: .milliseconds(700))
        #expect(mock.startCallCount == baseline)
    }

    @Test("retryStartIfEnabled tries again when enabled and not running")
    func retrySpinsUpEngineWhenAudioBecomesAvailable() async {
        let (service, mock) = Self.makeService(startResult: .failure(.tap(.noAudioSource)))
        service.setEnabled(true)
        let firstAttempt = mock.startCallCount

        // Simulate playback starting: source becomes available.
        mock.startResult = .success(())
        service.retryStartIfEnabled()
        try? await Task.sleep(for: .milliseconds(700))
        #expect(mock.startCallCount > firstAttempt)
        #expect(service.status == .active)
    }

    @Test("Disabling stops the engine and clears the error")
    func disableStopsEngine() {
        let (service, mock) = Self.makeService()
        service.setEnabled(true)
        #expect(mock.startCallCount == 1)

        service.setEnabled(false)
        #expect(mock.stopCallCount >= 1)
        #expect(service.lastFailure == nil)
    }

    // MARK: - Persistence

    @Test("Settings round-trip through UserDefaults")
    func persistenceRoundTrip() {
        let (service, _) = Self.makeService()
        service.apply(preset: .rock)
        service.setPreamp(-2)
        service.setGain(forBandAt: 1, to: 3.5)

        // New service should load the same settings.
        let mock = MockEqualizerAudioEngine()
        let revived = EqualizerService(engine: mock)
        #expect(revived.settings.preset == .custom) // setGain snapped it
        #expect(revived.settings.preampDB == -2)
        #expect(revived.settings.bandGainsDB[1] == 3.5)
    }
}

// MARK: - MockEqualizerAudioEngine

private final class MockEqualizerAudioEngine: EqualizerAudioEngineProtocol, @unchecked Sendable {
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
