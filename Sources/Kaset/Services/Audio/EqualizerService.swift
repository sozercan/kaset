import CoreAudio
import CoreGraphics
import Foundation
import Observation

// MARK: - EqualizerService

/// Single source of truth for the equalizer feature.
///
/// Observable state lives here so SwiftUI views bind directly to the
/// service; DSP lifecycle is delegated to ``EqualizerAudioEngine``;
/// persistence lives in `UserDefaults` under `Keys.settings`.
///
/// **Intent vs. reality.** ``EQSettings/isEnabled`` represents what the
/// user wants — it persists across launches and never auto-reverts. The
/// audio engine, in contrast, can only run when WebKit is actively
/// emitting audio (the Core Audio process tap needs a live source). When
/// the user enables the EQ before starting playback, ``status`` reports
/// ``Status/standby``; the next time ``retryStartIfEnabled()`` is called
/// (typically wired to `PlayerService.isPlaying` from `KasetApp`), the
/// engine spins up automatically.
@MainActor
@Observable
final class EqualizerService {
    static let shared = EqualizerService()

    // MARK: - Status

    /// Outward-facing engine state. Surfaced to the settings UI so users
    /// understand whether the EQ is currently active, waiting for audio,
    /// or held back by an error.
    enum Status: Equatable {
        case off
        case active
        case standby
        case permissionNeeded(message: String)
        case error(message: String)
    }

    // MARK: - Keys

    private enum Keys {
        static let settings = "settings.equalizer"
    }

    // MARK: - Observable state

    /// Current settings. Mutating this updates the engine and persists.
    var settings: EQSettings {
        didSet {
            guard self.settings != oldValue else { return }
            self.schedulePersist()
            self.syncEngine()
        }
    }

    /// Last failure raised by the engine. The UI reads it via ``status``;
    /// `nil` means "no error worth surfacing" (which includes the benign
    /// "no playback yet" case).
    private(set) var lastFailure: EqualizerAudioEngine.StartFailure?

    /// Set to `true` once we've inferred a permission denial from
    /// circumstantial evidence — typically: playback is known to be
    /// active, yet our Core Audio process-list scan returns empty, which
    /// means the sandbox is silently blocking the enumeration.
    private var inferredPermissionDenial: Bool = false

    // MARK: - Private

    private let engine: any EqualizerAudioEngineProtocol

    /// Cancelled and replaced on every ``retryStartIfEnabled()`` call so
    /// rapid `PlayerService.isPlaying` toggles don't pile up pending tasks.
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    /// Cancelled and replaced on every ``scheduleTapVerification()`` call
    /// for the same reason.
    @ObservationIgnored private var verificationTask: Task<Void, Never>?

    /// Cancelled and replaced on every settings mutation. A slider drag
    /// fires `didSet` at UI frame rate; debouncing keeps `UserDefaults`
    /// writes off the hot path while still flushing within ~250 ms of the
    /// last edit.
    @ObservationIgnored private var persistTask: Task<Void, Never>?

    /// Cancelled and replaced on every default-output change so a rapid
    /// plug/unplug storm doesn't pile up pending rebinds.
    @ObservationIgnored private var deviceChangeTask: Task<Void, Never>?

    /// Probe used by ``scheduleTapVerification`` to decide whether a silent
    /// tap really means "no permission" or just "user paused playback". A
    /// closure rather than a `PlayerServiceProtocol` reference keeps the
    /// coupling minimal — `KasetApp` wires `PlayerService.isPlaying` in.
    private let isPlaybackActive: @MainActor () -> Bool

    /// Current playback progress in seconds. Used by the tap verifier to
    /// distinguish "a couple of silent opening frames" from "we have stayed
    /// silent for a long stretch of active playback", which is much more
    /// indicative of a permission problem.
    private let playbackProgress: @MainActor () -> TimeInterval

    /// Screen / system-audio recording TCC helpers are injected for tests so
    /// the permission flow can be exercised without touching macOS privacy APIs.
    private let hasCapturePermission: @MainActor () -> Bool
    private let requestCapturePermission: @MainActor () -> Bool

    private let logger = DiagnosticsLogger.equalizer

    /// Reused across persist/load to avoid allocating a fresh coder on
    /// every slider tick (settings can mutate at UI frame rate during a
    /// drag).
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
    private static let persistDebounceInterval: Duration = .milliseconds(250)
    private static let tapVerificationPollInterval: Duration = .seconds(2)
    private static let tapVerificationProgressThreshold: TimeInterval = 8

    /// Set when the user explicitly turns the EQ on so the next start attempt
    /// may trigger the system permission prompt. Automatic retries consume
    /// this flag rather than reopening System Settings over and over.
    private var shouldRequestCapturePermissionOnNextStart: Bool = false

    // MARK: - Init

    private let defaults: UserDefaults

    /// Tests construct an isolated instance with a stub engine, stub
    /// playback probe, and a private `UserDefaults` suite; production code
    /// goes through ``shared``.
    init(
        engine: any EqualizerAudioEngineProtocol = EqualizerAudioEngine(),
        isPlaybackActive: @escaping @MainActor () -> Bool = { PlayerService.shared?.isPlaying ?? false },
        playbackProgress: @escaping @MainActor () -> TimeInterval = { PlayerService.shared?.progress ?? 0 },
        hasCapturePermission: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
        requestCapturePermission: @escaping @MainActor () -> Bool = { CGRequestScreenCaptureAccess() },
        defaults: UserDefaults = .standard
    ) {
        self.engine = engine
        self.isPlaybackActive = isPlaybackActive
        self.playbackProgress = playbackProgress
        self.hasCapturePermission = hasCapturePermission
        self.requestCapturePermission = requestCapturePermission
        self.defaults = defaults
        self.settings = Self.loadPersistedSettings(from: defaults)
        self.syncEngine()
        self.installDefaultOutputDeviceListener()
    }

    // MARK: - Output device tracking

    // Listener block invoked by Core Audio on its own callback queue
    // (`com.apple.root.default-qos`). Declared as a `nonisolated static`
    // constant so it doesn't inherit MainActor isolation from the
    // enclosing class — otherwise Swift 6's runtime isolation check
    // trips with `dispatch_assert_queue_fail` the first time the block
    // fires off-main. The hop to MainActor happens inside the Task.
    // swiftformat:disable:next modifierOrder
    nonisolated private static let defaultOutputDeviceListener:
        @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in
            Task { @MainActor in
                EqualizerService.shared.handleDefaultOutputDeviceChange()
            }
        }

    /// Rebinds the engine when the user plugs in headphones, switches to
    /// Bluetooth, etc. The aggregate device is tied to a specific output
    /// sub-device at creation time, so we tear down and rebuild on each
    /// system default-output change.
    private func installDefaultOutputDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            Self.defaultOutputDeviceListener
        )
        if status != noErr {
            self.logger.warning("failed to listen for default-output changes: \(status)")
        }
    }

    private func handleDefaultOutputDeviceChange() {
        guard self.settings.isEnabled else { return }
        // Coalesce bursts (plug/unplug flapping) into a single rebind
        // after a short debounce.
        self.deviceChangeTask?.cancel()
        self.deviceChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, !Task.isCancelled, self.settings.isEnabled else { return }
            self.logger.info("default output device changed — rebinding equalizer engine")
            self.engine.stop()
            self.attemptStart(playbackKnownActive: self.isPlaybackActive())
        }
    }

    // MARK: - Public API

    /// Applies a preset, replacing all band gains.
    func apply(preset: EQPreset) {
        var next = self.settings
        next.preset = preset
        next.bandGainsDB = preset.bandGainsDB
        next.clampGains()
        self.settings = next
    }

    /// Updates a single band gain (snaps the preset to `.custom`).
    func setGain(forBandAt index: Int, to gainDB: Float) {
        guard self.settings.bandGainsDB.indices.contains(index) else { return }
        var next = self.settings
        next.bandGainsDB[index] = gainDB
        next.preset = .custom
        next.clampGains()
        self.settings = next
    }

    /// Updates the preamp gain (does not change the preset).
    func setPreamp(_ gainDB: Float) {
        var next = self.settings
        next.preampDB = gainDB
        next.clampGains()
        self.settings = next
    }

    /// Enables or disables the equalizer.
    func setEnabled(_ enabled: Bool) {
        // A direct user toggle resets any inferred permission warning.
        // If permission is still missing, the next start attempt will
        // immediately infer it again.
        self.inferredPermissionDenial = false
        self.shouldRequestCapturePermissionOnNextStart = enabled
        var next = self.settings
        next.isEnabled = enabled
        self.settings = next
    }

    /// Resets to a flat, disabled equalizer (keeps `isEnabled` state).
    func reset() {
        var next = EQSettings.flat
        next.isEnabled = self.settings.isEnabled
        self.settings = next
    }

    /// Re-attempts engine start when the user wants the EQ on but the
    /// engine isn't running yet — typically called by `KasetApp` when
    /// `PlayerService.isPlaying` flips to `true`. A short delay gives the
    /// WebKit GPU process time to register with Core Audio's process list
    /// before we scan for it.
    func retryStartIfEnabled() {
        guard self.settings.isEnabled, !self.engine.isRunning else { return }
        self.retryTask?.cancel()
        self.retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled,
                  self.settings.isEnabled, !self.engine.isRunning
            else { return }
            self.attemptStart(playbackKnownActive: true)
        }
    }

    // MARK: - Status

    /// Computed status used by the UI badge.
    var status: Status {
        // Permission warnings outrank the engine's live state so the user
        // still sees the call-to-action while their persisted "enabled"
        // intent remains on.
        if self.inferredPermissionDenial {
            return .permissionNeeded(message: String(
                localized: "Open System Settings → Privacy & Security → Screen & System Audio Recording and enable Kaset, then retry playback or toggle the equalizer off and on."
            ))
        }
        guard self.settings.isEnabled else { return .off }
        if self.engine.isRunning { return .active }
        if let failure = self.lastFailure {
            if failure.isPermissionLikely {
                return .permissionNeeded(message: failure.userFacingMessage)
            }
            return .error(message: failure.userFacingMessage)
        }
        return .standby
    }

    // MARK: - Persistence

    private func schedulePersist() {
        self.persistTask?.cancel()
        self.persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.persistDebounceInterval)
            guard let self, !Task.isCancelled else { return }
            self.persist()
        }
    }

    private func persist() {
        do {
            let data = try Self.encoder.encode(self.settings)
            self.defaults.set(data, forKey: Keys.settings)
        } catch {
            self.logger.error("persist failed: \(error.localizedDescription)")
        }
    }

    private static func loadPersistedSettings(from defaults: UserDefaults) -> EQSettings {
        guard let data = defaults.data(forKey: Keys.settings) else {
            return .flat
        }
        do {
            var decoded = try Self.decoder.decode(EQSettings.self, from: data)
            decoded.clampGains()
            return decoded
        } catch {
            DiagnosticsLogger.equalizer.warning("failed to decode stored settings, falling back to flat: \(error.localizedDescription)")
            return .flat
        }
    }

    // MARK: - Engine sync

    private func syncEngine() {
        if self.settings.isEnabled {
            self.attemptStart(playbackKnownActive: false)
        } else {
            self.retryTask?.cancel()
            self.verificationTask?.cancel()
            self.deviceChangeTask?.cancel()
            self.engine.stop()
            self.lastFailure = nil
        }
    }

    /// Tries to bring the audio engine up. The `playbackKnownActive` flag
    /// changes how we interpret a `.noAudioSource` failure: at launch it's
    /// benign ("user hasn't pressed play yet"), but after we know playback
    /// is happening it strongly implies the sandbox is silently blocking
    /// our process-list scan due to missing audio-capture permission.
    private func attemptStart(playbackKnownActive: Bool) {
        if !self.hasCapturePermission() {
            if self.shouldRequestCapturePermissionOnNextStart {
                self.shouldRequestCapturePermissionOnNextStart = false
                _ = self.requestCapturePermission()
                guard self.hasCapturePermission() else {
                    self.logger.warning("capture permission request did not grant access yet")
                    self.flagPermissionDenial()
                    return
                }
            } else {
                self.logger.warning("capture permission missing — awaiting explicit user retry")
                self.flagPermissionDenial()
                return
            }
        }
        self.shouldRequestCapturePermissionOnNextStart = false

        switch self.engine.start() {
        case .success:
            self.lastFailure = nil
            self.inferredPermissionDenial = false
            self.engine.apply(settings: self.settings)
            // The pre-check in ProcessTapHelper handles the common case,
            // but TCC services occasionally disagree (different service,
            // stale cache, dev vs distribution signing). Verify a few
            // seconds later that the tap actually delivers audio.
            self.scheduleTapVerification()
        case let .failure(failure):
            if failure.isWaitingForPlayback, !playbackKnownActive {
                // Normal at launch — keep the standby badge.
                self.lastFailure = nil
            } else if failure.isWaitingForPlayback, playbackKnownActive {
                self.logger.warning(
                    "process scan empty while playback active — inferring permission denial"
                )
                self.flagPermissionDenial()
            } else if failure.isPermissionLikely {
                self.logger.warning("permission failure — \(String(describing: failure))")
                self.flagPermissionDenial()
            } else {
                // Other engine errors keep the toggle on (user intent
                // persists) and surface the message via ``status``.
                self.logger.warning("start failed — \(String(describing: failure))")
                self.lastFailure = failure
            }
        }
    }

    /// Records an inferred permission denial without mutating the
    /// persisted `isEnabled` intent. That lets future launches or playback
    /// state changes retry automatically once permission is restored.
    private func flagPermissionDenial() {
        self.verificationTask?.cancel()
        self.inferredPermissionDenial = true
        self.lastFailure = nil
        self.engine.stop()
    }

    /// After a successful start, poll until the tap either observes audio
    /// or playback has advanced a meaningful amount with nothing but zeros.
    /// A short silent intro is valid content; several seconds of active
    /// playback progress with a permanently silent tap is much more likely
    /// to mean the system admitted the tap but TCC is still denying audio.
    private func scheduleTapVerification() {
        self.verificationTask?.cancel()
        let initialProgress = self.playbackProgress()
        self.verificationTask = Task { @MainActor [weak self, initialProgress] in
            while true {
                try? await Task.sleep(for: Self.tapVerificationPollInterval)
                guard let self, !Task.isCancelled,
                      self.engine.isRunning, self.settings.isEnabled
                else { return }
                if self.engine.hasObservedAudio {
                    return
                }
                guard self.isPlaybackActive() else { continue }

                let progressedPlayback = max(0, self.playbackProgress() - initialProgress)
                guard progressedPlayback >= Self.tapVerificationProgressThreshold else { continue }
                let progressedPlaybackString = String(format: "%.1f", progressedPlayback)

                self.logger.warning(
                    "tap stayed silent for \(progressedPlaybackString)s of active playback — inferring permission denial"
                )
                self.flagPermissionDenial()
                return
            }
        }
    }
}
