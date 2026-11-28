import CoreAudio
import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class EqualizerService {
    static let shared = EqualizerService()

    enum Status: Equatable {
        case off
        case active
        case standby
        case permissionNeeded(message: String)
        case error(message: String)
    }

    private enum Keys {
        static let settings = "settings.equalizer"
    }

    var settings: EQSettings {
        didSet {
            guard self.settings != oldValue else { return }
            self.schedulePersist()
            self.syncEngine()
        }
    }

    private(set) var lastFailure: EqualizerAudioEngine.StartFailure?

    private var inferredPermissionDenial: Bool = false

    private let engine: any EqualizerAudioEngineProtocol

    @ObservationIgnored private var retryTask: Task<Void, Never>?

    @ObservationIgnored private var verificationTask: Task<Void, Never>?

    @ObservationIgnored private var persistTask: Task<Void, Never>?

    @ObservationIgnored private var deviceChangeTask: Task<Void, Never>?

    @ObservationIgnored private var scanRetryTask: Task<Void, Never>?

    private var scanRetryCount: Int = 0
    private let scanRetryInterval: Duration

    private let isPlaybackActive: @MainActor () -> Bool

    private let playbackProgress: @MainActor () -> TimeInterval

    private let isFeatureAvailable: @MainActor () -> Bool

    private let hasCapturePermission: @MainActor () -> Bool
    private let requestCapturePermission: @MainActor () -> Bool

    private let logger = DiagnosticsLogger.equalizer

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
    private static let persistDebounceInterval: Duration = .milliseconds(250)
    private static let tapVerificationPollInterval: Duration = .seconds(2)
    private static let tapVerificationProgressThreshold: TimeInterval = 8
    private static let maxScanRetries = 5

    private var shouldRequestCapturePermissionOnNextStart: Bool = false

    private let defaults: UserDefaults

    init(
        engine: any EqualizerAudioEngineProtocol = EqualizerAudioEngine(),
        isPlaybackActive: @escaping @MainActor () -> Bool = { PlayerService.shared?.isPlaying ?? false },
        playbackProgress: @escaping @MainActor () -> TimeInterval = { PlayerService.shared?.progress ?? 0 },
        isFeatureAvailable: @escaping @MainActor () -> Bool = { SettingsManager.shared.appExperience.includesMusic },
        hasCapturePermission: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
        requestCapturePermission: @escaping @MainActor () -> Bool = { CGRequestScreenCaptureAccess() },
        scanRetryInterval: Duration = .seconds(2),
        defaults: UserDefaults = .standard
    ) {
        self.engine = engine
        self.isPlaybackActive = isPlaybackActive
        self.playbackProgress = playbackProgress
        self.isFeatureAvailable = isFeatureAvailable
        self.hasCapturePermission = hasCapturePermission
        self.requestCapturePermission = requestCapturePermission
        self.scanRetryInterval = scanRetryInterval
        self.defaults = defaults
        self.settings = Self.loadPersistedSettings(from: defaults)
        self.syncEngine()
        self.installDefaultOutputDeviceListener()
    }

    // swiftformat:disable:next modifierOrder
    nonisolated private static let defaultOutputDeviceListener:
        @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in
            Task { @MainActor in
                EqualizerService.shared.handleDefaultOutputDeviceChange()
            }
        }

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
        guard self.settings.isEnabled, self.isFeatureAvailable() else { return }
        self.deviceChangeTask?.cancel()
        self.deviceChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, !Task.isCancelled, self.settings.isEnabled, self.isFeatureAvailable() else { return }
            self.logger.info("default output device changed — rebinding equalizer engine")
            self.engine.stop()
            self.attemptStart(playbackKnownActive: self.isPlaybackActive())
        }
    }

    func apply(preset: EQPreset) {
        var next = self.settings
        next.preset = preset
        next.bandGainsDB = preset.bandGainsDB
        next.clampGains()
        self.settings = next
    }

    func setGain(forBandAt index: Int, to gainDB: Float) {
        guard self.settings.bandGainsDB.indices.contains(index) else { return }
        var next = self.settings
        next.bandGainsDB[index] = gainDB
        next.preset = .custom
        next.clampGains()
        self.settings = next
    }

    func setPreamp(_ gainDB: Float) {
        var next = self.settings
        next.preampDB = gainDB
        next.clampGains()
        self.settings = next
    }

    func setEnabled(_ enabled: Bool) {
        self.inferredPermissionDenial = false
        self.scanRetryCount = 0
        self.shouldRequestCapturePermissionOnNextStart = enabled
        var next = self.settings
        next.isEnabled = enabled
        self.settings = next
        if enabled, self.isPlaybackActive() {
            self.retryStartIfEnabled()
        }
    }

    func reset() {
        var next = EQSettings.flat
        next.isEnabled = self.settings.isEnabled
        self.settings = next
    }

    func syncForAppExperience() {
        self.syncEngine()
    }

    func retryStartIfEnabled() {
        guard self.settings.isEnabled, self.isFeatureAvailable(), !self.engine.isRunning else { return }
        self.scanRetryCount = 0
        self.scanRetryTask?.cancel()
        self.retryTask?.cancel()
        self.retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled,
                  self.settings.isEnabled, self.isFeatureAvailable(), !self.engine.isRunning
            else { return }
            self.attemptStart(playbackKnownActive: true)
        }
    }

    var status: Status {
        if self.inferredPermissionDenial {
            return .permissionNeeded(message: String(
                localized: "Open System Settings → Privacy & Security → Screen & System Audio Recording and enable Kaset, then retry playback or toggle the equalizer off and on."
            ))
        }
        guard self.settings.isEnabled else { return .off }
        if self.engine.isRunning {
            return .active
        }
        if let failure = self.lastFailure {
            if failure.isPermissionLikely {
                return .permissionNeeded(message: failure.userFacingMessage)
            }
            return .error(message: failure.userFacingMessage)
        }
        return .standby
    }

    private func schedulePersist() {
        self.persistTask?.cancel()
        self.persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.persistDebounceInterval)
            guard let self, !Task.isCancelled else { return }
            self.persist()
        }
    }

    func awaitPendingPersistence() async {
        let task = self.persistTask
        await task?.value
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

    private func syncEngine() {
        if self.settings.isEnabled, self.isFeatureAvailable() {
            self.attemptStart(playbackKnownActive: false)
        } else {
            self.retryTask?.cancel()
            self.verificationTask?.cancel()
            self.deviceChangeTask?.cancel()
            self.scanRetryTask?.cancel()
            self.engine.stop()
            self.lastFailure = nil
        }
    }

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
            self.scanRetryCount = 0
            self.engine.apply(settings: self.settings)
            self.scheduleTapVerification()
        case let .failure(failure):
            if failure.isWaitingForPlayback {
                self.lastFailure = nil
                self.inferredPermissionDenial = false
                if playbackKnownActive {
                    self.scheduleScanRetry()
                }
            } else if failure.isPermissionLikely {
                self.logger.warning("permission failure — \(String(describing: failure))")
                self.flagPermissionDenial()
            } else {
                self.logger.warning("start failed — \(String(describing: failure))")
                self.lastFailure = failure
            }
        }
    }

    private func scheduleScanRetry() {
        guard self.scanRetryCount < Self.maxScanRetries else {
            self.logger.warning("no WebKit audio process to tap after \(Self.maxScanRetries) rescans")
            return
        }
        self.scanRetryCount += 1
        self.scanRetryTask?.cancel()
        let interval = self.scanRetryInterval
        self.scanRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled,
                  self.settings.isEnabled, !self.engine.isRunning,
                  self.isPlaybackActive()
            else { return }
            self.attemptStart(playbackKnownActive: true)
        }
    }

    private func flagPermissionDenial() {
        self.verificationTask?.cancel()
        self.inferredPermissionDenial = true
        self.lastFailure = nil
        self.engine.stop()
    }

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
