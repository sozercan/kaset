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
            self.persist()
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
    private var retryTask: Task<Void, Never>?

    /// Cancelled and replaced on every ``scheduleTapVerification()`` call
    /// for the same reason.
    private var verificationTask: Task<Void, Never>?

    /// Probe used by ``scheduleTapVerification`` to decide whether a silent
    /// tap really means "no permission" or just "user paused playback". A
    /// closure rather than a `PlayerServiceProtocol` reference keeps the
    /// coupling minimal — `KasetApp` wires `PlayerService.isPlaying` in.
    private let isPlaybackActive: @MainActor () -> Bool

    private let logger = DiagnosticsLogger.equalizer
    private static let logger = DiagnosticsLogger.equalizer

    /// Reused across persist/load to avoid allocating a fresh coder on
    /// every slider tick (settings can mutate at UI frame rate during a
    /// drag).
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: - Init

    /// Tests construct an isolated instance with a stub engine and a stub
    /// playback probe; production code goes through ``shared``.
    init(
        engine: any EqualizerAudioEngineProtocol = EqualizerAudioEngine(),
        isPlaybackActive: @escaping @MainActor () -> Bool = { PlayerService.shared?.isPlaying ?? false }
    ) {
        self.engine = engine
        self.isPlaybackActive = isPlaybackActive
        self.settings = Self.loadPersistedSettings()
        self.syncEngine()
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
        if enabled {
            // The user is asking to turn the EQ on — clear any sticky
            // permission warning so we attempt fresh; if permission really
            // is still missing, the next start attempt will surface it
            // again.
            self.inferredPermissionDenial = false
        }
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
        // Permission warnings outrank toggle state — when we've inferred
        // a denial we want the user to see the call-to-action even after
        // the toggle has been auto-disabled below.
        if self.inferredPermissionDenial {
            return .permissionNeeded(message: String(
                localized: "Open System Settings → Privacy & Security → Screen & System Audio Recording and enable Kaset, then toggle the equalizer on again."
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

    private func persist() {
        do {
            let data = try Self.encoder.encode(self.settings)
            UserDefaults.standard.set(data, forKey: Keys.settings)
        } catch {
            self.logger.error("persist failed: \(error.localizedDescription)")
        }
    }

    private static func loadPersistedSettings() -> EQSettings {
        guard let data = UserDefaults.standard.data(forKey: Keys.settings) else {
            return .flat
        }
        do {
            var decoded = try Self.decoder.decode(EQSettings.self, from: data)
            decoded.clampGains()
            return decoded
        } catch {
            Self.logger.warning("failed to decode stored settings, falling back to flat: \(error.localizedDescription)")
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
            self.engine.stop()
            self.lastFailure = nil
            // `inferredPermissionDenial` deliberately survives the recursive
            // sync triggered by ``flagPermissionDenialAndDisable`` so the
            // permission CTA outlives the auto-toggle-off.
        }
    }

    /// Tries to bring the audio engine up. The `playbackKnownActive` flag
    /// changes how we interpret a `.noAudioSource` failure: at launch it's
    /// benign ("user hasn't pressed play yet"), but after we know playback
    /// is happening it strongly implies the sandbox is silently blocking
    /// our process-list scan due to missing audio-capture permission.
    private func attemptStart(playbackKnownActive: Bool) {
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
                self.flagPermissionDenialAndDisable()
            } else if failure.isPermissionLikely {
                self.logger.warning("permission failure — \(String(describing: failure))")
                self.flagPermissionDenialAndDisable()
            } else {
                // Other engine errors keep the toggle on (user intent
                // persists) and surface the message via ``status``.
                self.logger.warning("start failed — \(String(describing: failure))")
                self.lastFailure = failure
            }
        }
    }

    /// Records an inferred permission denial and auto-disables the toggle
    /// so the UI matches the engine's actual state. The status row keeps
    /// showing the permission CTA via ``inferredPermissionDenial``.
    ///
    /// The `self.settings = next` assignment recurses into ``syncEngine``
    /// via the property's `didSet`; that call takes the disabled branch
    /// (which intentionally preserves ``inferredPermissionDenial``) and
    /// stops at depth 1.
    private func flagPermissionDenialAndDisable() {
        self.inferredPermissionDenial = true
        self.lastFailure = nil
        guard self.settings.isEnabled else { return }
        var next = self.settings
        next.isEnabled = false
        self.settings = next
    }

    /// After a successful start, give the tap ~2 s to deliver audio. If it
    /// stays completely silent while WebKit is supposed to be playing,
    /// that's the symptom of a TCC denial that snuck past the preflight
    /// check (different TCC service, stale cache, etc.). Tear down so we
    /// stop muting WebKit and surface the permission CTA.
    private func scheduleTapVerification() {
        self.verificationTask?.cancel()
        self.verificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled,
                  self.engine.isRunning, self.settings.isEnabled
            else { return }
            guard self.isPlaybackActive(), !self.engine.hasObservedAudio else { return }
            self.logger.warning(
                "tap stayed silent for ~2s while playback active — inferring permission denial"
            )
            self.engine.stop()
            self.flagPermissionDenialAndDisable()
        }
    }
}
