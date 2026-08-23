import Foundation
import Observation
import UserNotifications

/// Posts silent local notifications when the current track changes.
@MainActor
final class NotificationService {
    private let playerService: PlayerService
    private let settingsManager: SettingsManager
    private let logger = DiagnosticsLogger.notification
    private static let loadingResolutionCheckInterval: Duration = .milliseconds(10)
    private static let loadingResolutionMaxChecks = 50
    /// Whether player observation is currently registered.
    private var isObservationActive = false
    /// Monotonic token used to ignore stale one-shot observation callbacks after stopObserving().
    private var observationGeneration = 0
    /// Bounded follow-up task used only while a current track has unresolved metadata.
    private var loadingResolutionTask: Task<Void, Never>?
    /// Track ID currently being checked for loading-placeholder resolution.
    private var pendingLoadingTrackId: String?
    /// Last player track ID observed by the event-driven watcher.
    private var previousObservedTrackId: String?
    /// Last playback-active value observed by the event-driven watcher.
    private var previousObservedIsPlaying = false
    /// Tracks the last notified track to prevent duplicate notifications.
    /// Internal for testing.
    private(set) var lastNotifiedTrackId: String?

    init(playerService: PlayerService, settingsManager: SettingsManager = .shared) {
        self.playerService = playerService
        self.settingsManager = settingsManager
        self.requestAuthorization()
        self.startObserving()
    }

    // MARK: - Authorization

    private func requestAuthorization() {
        // UNUserNotificationCenter crashes without an app bundle (e.g., unit/performance tests)
        guard Bundle.main.bundleIdentifier != nil, !UITestConfig.isRunningUnitTests else { return }
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert])
                self.logger.info("Notification authorization: \(granted)")
            } catch {
                self.logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Observation

    private func startObserving() {
        guard !self.isObservationActive else { return }

        self.isObservationActive = true
        self.observationGeneration += 1
        let generation = self.observationGeneration

        // Match the former polling loop's first cycle: treat an already-current
        // track as a change, while preserving the current playback-active edge.
        self.previousObservedTrackId = nil
        self.previousObservedIsPlaying = self.playerService.isPlaying
        let initialTrackToNotify = self.notificationCandidateForCurrentState()

        self.registerPlayerObservation(generation: generation)

        guard let initialTrackToNotify else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isObserving(generation: generation) else { return }
            await self.postTrackNotification(initialTrackToNotify)
        }
    }

    private func registerPlayerObservation(generation: Int) {
        guard self.isObserving(generation: generation) else { return }

        let playerService = self.playerService
        withObservationTracking {
            _ = playerService.currentTrack
            _ = playerService.currentTrack?.id
            _ = playerService.currentTrack?.title
            _ = playerService.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handlePlayerObservationChanged(generation: generation)
            }
        }
    }

    private func handlePlayerObservationChanged(generation: Int) async {
        guard self.isObserving(generation: generation) else { return }

        let trackToNotify = self.notificationCandidateForCurrentState()

        // Re-register before posting so changes that arrive while UserNotifications
        // is awaiting do not get dropped.
        self.registerPlayerObservation(generation: generation)

        guard let trackToNotify, self.isObserving(generation: generation) else { return }
        await self.postTrackNotification(trackToNotify)
    }

    private func notificationCandidateForCurrentState() -> Song? {
        let currentTrack = self.playerService.currentTrack
        let isPlaying = self.playerService.isPlaying

        defer {
            if currentTrack == nil {
                self.previousObservedTrackId = nil
            } else if currentTrack?.title != "Loading..." {
                self.previousObservedTrackId = currentTrack?.id
            }
            self.previousObservedIsPlaying = isPlaying
        }

        guard let track = currentTrack else { return nil }

        if track.title == "Loading..." {
            if isPlaying, track.id != self.lastNotifiedTrackId {
                self.scheduleLoadingResolutionCheck(for: track.id)
            }
            return nil
        }

        // Notify once active playback starts for a new, fully resolved track.
        guard track.id != self.lastNotifiedTrackId else { return nil }

        let trackChanged = track.id != self.previousObservedTrackId
        let playbackJustStarted = isPlaying && !self.previousObservedIsPlaying

        guard isPlaying, trackChanged || playbackJustStarted else { return nil }

        self.clearLoadingResolutionCheck()
        self.lastNotifiedTrackId = track.id
        return track
    }

    private func scheduleLoadingResolutionCheck(for trackId: String) {
        guard self.pendingLoadingTrackId != trackId else { return }

        self.loadingResolutionTask?.cancel()
        self.pendingLoadingTrackId = trackId
        let generation = self.observationGeneration

        self.loadingResolutionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for _ in 0 ..< Self.loadingResolutionMaxChecks {
                guard self.isObserving(generation: generation), !Task.isCancelled else { return }

                await Task.yield()
                if let trackToNotify = self.loadingResolutionNotificationCandidate(for: trackId) ?? self.notificationCandidateForCurrentState(),
                   self.isObserving(generation: generation)
                {
                    await self.postTrackNotification(trackToNotify)
                    return
                }

                guard self.playerService.currentTrack?.id == trackId,
                      self.playerService.currentTrack?.title == "Loading..."
                else {
                    self.clearLoadingResolutionCheck()
                    return
                }

                do {
                    try await Task.sleep(for: Self.loadingResolutionCheckInterval)
                } catch {
                    return
                }
            }

            self.clearLoadingResolutionCheck()
        }
    }

    private func loadingResolutionNotificationCandidate(for trackId: String) -> Song? {
        guard let track = self.playerService.currentTrack,
              track.id == trackId,
              track.title != "Loading...",
              self.playerService.isPlaying,
              track.id != self.lastNotifiedTrackId
        else { return nil }

        self.previousObservedTrackId = track.id
        self.previousObservedIsPlaying = true
        self.clearLoadingResolutionCheck()
        self.lastNotifiedTrackId = track.id
        return track
    }

    private func clearLoadingResolutionCheck() {
        self.pendingLoadingTrackId = nil
        self.loadingResolutionTask = nil
    }

    private func isObserving(generation: Int) -> Bool {
        self.isObservationActive && self.observationGeneration == generation
    }

    /// Whether the observation registration is active.
    var isObserving: Bool {
        self.isObservationActive
    }

    func stopObserving() {
        guard self.isObservationActive else { return }

        self.isObservationActive = false
        self.observationGeneration += 1
        self.loadingResolutionTask?.cancel()
        self.clearLoadingResolutionCheck()
    }

    // MARK: - Notification

    private func postTrackNotification(_ track: Song) async {
        // UNUserNotificationCenter crashes without an app bundle (e.g., unit/performance tests)
        guard Bundle.main.bundleIdentifier != nil, !UITestConfig.isRunningUnitTests else { return }
        // Check if notifications are enabled in settings
        guard self.settingsManager.showNowPlayingNotifications else {
            self.logger.debug("Notifications disabled in settings, skipping: \(track.title)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = track.title
        content.body = track.artistsDisplay.isEmpty ? "Unknown Artist" : track.artistsDisplay
        content.sound = nil // Silent notification

        let request = UNNotificationRequest(
            identifier: "track-change-\(track.id)",
            content: content,
            trigger: nil // Deliver immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            self.logger.debug("Posted notification for: \(track.title)")
        } catch {
            self.logger.error("Failed to post notification: \(error.localizedDescription)")
        }
    }
}
