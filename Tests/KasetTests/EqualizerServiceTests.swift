import Foundation
import Testing
@testable import Kaset

// MARK: - EqualizerServiceTests

/// Tests for `EqualizerService`. Uses a mock `EqualizerAudioEngineProtocol`
/// so the real Core Audio process tap is never touched.
@Suite(.serialized, .tags(.service))
@MainActor
struct EqualizerServiceTests {
    private static let suiteName = "com.kaset.test.EqualizerService"

    private final class PlaybackProbe: @unchecked Sendable {
        var progress: TimeInterval = 0
    }

    private final class PermissionProbe: @unchecked Sendable {
        var granted = false
    }

    private struct TestHarness {
        let service: EqualizerService
        let mock: MockEqualizerAudioEngine
        let defaults: UserDefaults
    }

    /// Returns a service backed by a fresh mock engine, using an isolated
    /// `UserDefaults` suite so tests never touch the shared production
    /// defaults domain.
    private static func makeService(
        startResult: Result<Void, EqualizerAudioEngine.StartFailure> = .success(()),
        isPlaybackActive: @escaping @MainActor () -> Bool = { false },
        playbackProgress: @escaping @MainActor () -> TimeInterval = { 0 },
        hasCapturePermission: @escaping @MainActor () -> Bool = { true },
        requestCapturePermission: @escaping @MainActor () -> Bool = { true }
    ) -> TestHarness {
        let defaults = UserDefaults(suiteName: self.suiteName)!
        defaults.removePersistentDomain(forName: self.suiteName)
        let mock = MockEqualizerAudioEngine(startResult: startResult)
        let service = EqualizerService(
            engine: mock,
            isPlaybackActive: isPlaybackActive,
            playbackProgress: playbackProgress,
            hasCapturePermission: hasCapturePermission,
            requestCapturePermission: requestCapturePermission,
            defaults: defaults
        )
        return TestHarness(service: service, mock: mock, defaults: defaults)
    }

    // MARK: - Preset application

    @Test("Applying a preset replaces every band gain")
    func applyPresetReplacesBands() {
        let harness = Self.makeService()
        let service = harness.service
        service.apply(preset: .bassBooster)

        #expect(service.settings.preset == .bassBooster)
        #expect(service.settings.bandGainsDB == EQPreset.bassBooster.bandGainsDB)
    }

    @Test("Applying a preset clamps any out-of-range values")
    func applyPresetClamps() {
        let harness = Self.makeService()
        let service = harness.service
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
        let harness = Self.makeService()
        let service = harness.service
        service.apply(preset: .rock)
        #expect(service.settings.preset == .rock)

        service.setGain(forBandAt: 0, to: 1.5)
        #expect(service.settings.preset == .custom)
        #expect(service.settings.bandGainsDB[0] == 1.5)
    }

    @Test("setGain clamps to the legal range")
    func setGainClamps() {
        let harness = Self.makeService()
        let service = harness.service
        service.setGain(forBandAt: 0, to: 999)
        #expect(service.settings.bandGainsDB[0] == EQSettings.maxGainDB)
        service.setGain(forBandAt: 0, to: -999)
        #expect(service.settings.bandGainsDB[0] == EQSettings.minGainDB)
    }

    @Test("setGain ignores out-of-bounds indices")
    func setGainIgnoresInvalidIndex() {
        let harness = Self.makeService()
        let service = harness.service
        let original = service.settings.bandGainsDB
        service.setGain(forBandAt: 999, to: 5)
        #expect(service.settings.bandGainsDB == original)
    }

    // MARK: - Preamp

    @Test("setPreamp does not change the active preset")
    func setPreampPreservesPreset() {
        let harness = Self.makeService()
        let service = harness.service
        service.apply(preset: .pop)
        service.setPreamp(-3)
        #expect(service.settings.preset == .pop)
        #expect(service.settings.preampDB == -3)
    }

    // MARK: - Reset

    @Test("reset returns to flat bands but preserves isEnabled")
    func resetPreservesEnabledState() {
        let harness = Self.makeService()
        let service = harness.service
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
        let harness = Self.makeService()
        let service = harness.service
        let mock = harness.mock
        service.apply(preset: .jazz)
        service.setEnabled(true)

        #expect(mock.startCallCount == 1)
        #expect(mock.lastAppliedSettings?.preset == .jazz)
        #expect(service.lastFailure == nil)
    }

    @Test("Explicit tap-creation failure preserves enabled intent and surfaces the permission CTA")
    func permissionFailurePreservesEnabledIntent() {
        let harness = Self.makeService(startResult: .failure(.tap(.tapCreation(-1))))
        let service = harness.service
        let mock = harness.mock
        service.setEnabled(true)

        #expect(mock.startCallCount == 1)
        // User intent stays enabled so future playback changes or a
        // relaunch can retry automatically once permission is restored.
        #expect(service.settings.isEnabled == true)
        if case .permissionNeeded = service.status {
            // expected
        } else {
            Issue.record("Expected .permissionNeeded status, got \(service.status)")
        }
    }

    @Test("Directly enabling the EQ requests capture permission when it is missing")
    func enablingRequestsCapturePermission() {
        let permission = PermissionProbe()
        var requestCount = 0
        let harness = Self.makeService(
            hasCapturePermission: { permission.granted },
            requestCapturePermission: {
                requestCount += 1
                permission.granted = true
                return true
            }
        )
        let service = harness.service
        let mock = harness.mock

        service.setEnabled(true)

        #expect(requestCount == 1)
        #expect(mock.startCallCount == 1)
        #expect(service.status == .active)
    }

    @Test("Denied capture permission keeps intent enabled and avoids starting the engine")
    func deniedCapturePermissionDoesNotStartEngine() {
        var requestCount = 0
        let harness = Self.makeService(
            hasCapturePermission: { false },
            requestCapturePermission: {
                requestCount += 1
                return false
            }
        )
        let service = harness.service
        let mock = harness.mock

        service.setEnabled(true)

        #expect(requestCount == 1)
        #expect(mock.startCallCount == 0)
        #expect(service.settings.isEnabled == true)
        if case .permissionNeeded = service.status {
            // expected
        } else {
            Issue.record("Expected .permissionNeeded status, got \(service.status)")
        }
    }

    @Test("Permission prompt is not auto-requested from persisted enabled state on launch")
    func launchDoesNotPromptWithoutExplicitUserRetry() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        let persisted = EQSettings(
            isEnabled: true,
            preampDB: 0,
            bandGainsDB: Array(repeating: 0, count: EQBand.defaultBands.count),
            preset: .flat
        )
        try defaults.set(JSONEncoder().encode(persisted), forKey: "settings.equalizer")

        var requestCount = 0
        let mock = MockEqualizerAudioEngine()
        let service = EqualizerService(
            engine: mock,
            hasCapturePermission: { false },
            requestCapturePermission: {
                requestCount += 1
                return true
            },
            defaults: defaults
        )

        #expect(requestCount == 0)
        #expect(mock.startCallCount == 0)
        if case .permissionNeeded = service.status {
            // expected
        } else {
            Issue.record("Expected .permissionNeeded status, got \(service.status)")
        }
    }

    @Test("retryStartIfEnabled retries automatically after permission is restored")
    func retryAfterPermissionRestoreSucceeds() async {
        let harness = Self.makeService(startResult: .failure(.tap(.tapCreation(-1))))
        let service = harness.service
        let mock = harness.mock
        service.setEnabled(true)
        #expect(service.settings.isEnabled == true)

        // User grants permission; the next automatic retry should recover
        // without losing the saved enabled preference.
        mock.startResult = .success(())
        service.retryStartIfEnabled()
        try? await Task.sleep(for: .milliseconds(700))
        #expect(service.settings.isEnabled == true)
        #expect(service.status == .active)
    }

    @Test("Manual disable clears the sticky permission warning")
    func manualDisableClearsPermissionWarning() {
        let harness = Self.makeService(startResult: .failure(.tap(.tapCreation(-1))))
        let service = harness.service
        service.setEnabled(true)
        if case .permissionNeeded = service.status {
            // expected
        } else {
            Issue.record("Expected .permissionNeeded status, got \(service.status)")
        }

        service.setEnabled(false)
        #expect(service.status == .off)
        #expect(service.settings.isEnabled == false)
    }

    @Test("No-audio-source failure stays silent (waiting for playback)")
    func noAudioSourceShowsStandby() {
        let harness = Self.makeService(startResult: .failure(.tap(.noAudioSource)))
        let service = harness.service
        let mock = harness.mock
        service.setEnabled(true)

        #expect(mock.startCallCount == 1)
        #expect(service.settings.isEnabled == true)
        #expect(service.lastFailure == nil)
        #expect(service.status == .standby)
    }

    @Test("retryStartIfEnabled is a no-op when toggle is off")
    func retryNoOpsWhenDisabled() async {
        let harness = Self.makeService()
        let service = harness.service
        let mock = harness.mock
        service.setEnabled(false)
        let baseline = mock.startCallCount

        service.retryStartIfEnabled()
        try? await Task.sleep(for: .milliseconds(700))
        #expect(mock.startCallCount == baseline)
    }

    @Test("retryStartIfEnabled tries again when enabled and not running")
    func retrySpinsUpEngineWhenAudioBecomesAvailable() async {
        let harness = Self.makeService(startResult: .failure(.tap(.noAudioSource)))
        let service = harness.service
        let mock = harness.mock
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
        let harness = Self.makeService()
        let service = harness.service
        let mock = harness.mock
        service.setEnabled(true)
        #expect(mock.startCallCount == 1)

        service.setEnabled(false)
        #expect(mock.stopCallCount >= 1)
        #expect(service.lastFailure == nil)
    }

    // MARK: - Persistence

    @Test("Settings round-trip through UserDefaults")
    func persistenceRoundTrip() async {
        let harness = Self.makeService()
        let service = harness.service
        let defaults = harness.defaults
        service.apply(preset: .rock)
        service.setPreamp(-2)
        service.setGain(forBandAt: 1, to: 3.5)

        // Persistence is debounced; wait past the debounce window.
        try? await Task.sleep(for: .milliseconds(400))

        // New service should load the same settings from the same suite.
        let mock = MockEqualizerAudioEngine()
        let revived = EqualizerService(engine: mock, defaults: defaults)
        #expect(revived.settings.preset == .custom) // setGain snapped it
        #expect(revived.settings.preampDB == -2)
        #expect(revived.settings.bandGainsDB[1] == 3.5)
    }

    @Test("Decoded settings with a mismatched band-count are normalised to the default shape")
    func persistenceNormalisesBandCount() throws {
        // Fresh defaults suite (discarding the makeService harness; we
        // need a clean UserDefaults to pre-seed before the service init
        // reads from it).
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        let shortPayload = EQSettings(
            isEnabled: false,
            preampDB: 0,
            bandGainsDB: [1, 2, 3],
            preset: .custom
        )
        let data = try? JSONEncoder().encode(shortPayload)
        defaults.set(data, forKey: "settings.equalizer")

        let revived = EqualizerService(engine: MockEqualizerAudioEngine(), defaults: defaults)
        #expect(revived.settings.bandGainsDB.count == EQBand.defaultBands.count)
        #expect(revived.settings.bandGainsDB.prefix(3) == [1, 2, 3])
    }

    // MARK: - Tap silence verification

    @Test("Silent tap while active playback barely advances does not infer permission denial")
    func shortSilentPlaybackDoesNotInferPermissionDenial() async {
        let probe = PlaybackProbe()
        let harness = Self.makeService(
            isPlaybackActive: { true },
            playbackProgress: { probe.progress }
        )
        let service = harness.service
        let mock = harness.mock
        mock.hasObservedAudio = false
        service.setEnabled(true)
        #expect(service.status == .active)
        let baselineStopCount = mock.stopCallCount

        probe.progress = 1.5
        try? await Task.sleep(for: .milliseconds(2300))

        #expect(mock.stopCallCount == baselineStopCount)
        #expect(service.status == .active)
        service.setEnabled(false)
    }

    @Test("Silent tap after a long stretch of active playback infers permission denial")
    func silentTapInfersPermissionDenial() async {
        let probe = PlaybackProbe()
        let harness = Self.makeService(
            isPlaybackActive: { true },
            playbackProgress: { probe.progress }
        )
        let service = harness.service
        let mock = harness.mock
        mock.hasObservedAudio = false
        service.setEnabled(true)
        #expect(service.status == .active)
        let baselineStopCount = mock.stopCallCount

        probe.progress = 8
        try? await Task.sleep(for: .milliseconds(2300))
        #expect(mock.stopCallCount > baselineStopCount)
        #expect(service.settings.isEnabled == true)
        if case .permissionNeeded = service.status {
            // expected
        } else {
            Issue.record("Expected .permissionNeeded, got \(service.status)")
        }
    }

    @Test("Permission failures do not overwrite the persisted enabled preference")
    func permissionFailurePreservesPersistedEnabledPreference() async {
        let harness = Self.makeService(startResult: .failure(.tap(.tapCreation(-1))))
        let service = harness.service
        let defaults = harness.defaults
        service.setEnabled(true)
        if case .permissionNeeded = service.status {
            // expected
        } else {
            Issue.record("Expected .permissionNeeded status, got \(service.status)")
        }

        try? await Task.sleep(for: .milliseconds(400))

        let revived = EqualizerService(engine: MockEqualizerAudioEngine(), defaults: defaults)
        #expect(revived.settings.isEnabled == true)
    }

    @Test("Rapid retry toggling coalesces to a single engine start")
    func retryCoalescesRapidToggles() async {
        let harness = Self.makeService(startResult: .failure(.tap(.noAudioSource)))
        let service = harness.service
        let mock = harness.mock
        service.setEnabled(true)
        let baseline = mock.startCallCount

        mock.startResult = .success(())
        // Five rapid calls should all cancel each other — only the final
        // scheduled attempt runs.
        for _ in 0 ..< 5 {
            service.retryStartIfEnabled()
        }
        try? await Task.sleep(for: .milliseconds(700))

        #expect(mock.startCallCount == baseline + 1)
    }
}
