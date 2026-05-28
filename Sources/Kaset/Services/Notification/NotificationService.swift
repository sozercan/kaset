import Foundation
import UserNotifications

/// Posts silent local notifications when the current track changes.
@MainActor
final class NotificationService {
    private let playerService: PlayerService
    private let settingsManager: SettingsManager
    private let logger = DiagnosticsLogger.notification
    // swiftformat:disable modifierOrder
    /// Task for observing player changes, cancelled in deinit.
    /// nonisolated(unsafe) required for deinit access; Swift 6.2 warning is expected.
    nonisolated(unsafe) private var observationTask: Task<Void, Never>?
    // swiftformat:enable modifierOrder
    /// Tracks the last notified track to prevent duplicate notifications.
    /// Internal for testing.
    private(set) var lastNotifiedTrackId: String?

    init(playerService: PlayerService, settingsManager: SettingsManager = .shared) {
        self.playerService = playerService
        self.settingsManager = settingsManager
        self.requestAuthorization()
        self.startObserving()
    }

    deinit {
        observationTask?.cancel()
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
        self.observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var previousTrack: Song?
            var previousIsPlaying = self.playerService.isPlaying

            while !Task.isCancelled {
                let currentTrack = self.playerService.currentTrack
                let isPlaying = self.playerService.isPlaying

                // Notify once active playback starts for a new, fully resolved track.
                if let track = currentTrack,
                   track.id != self.lastNotifiedTrackId,
                   track.title != "Loading..."
                {
                    let trackChanged = track.id != previousTrack?.id
                    let playbackJustStarted = isPlaying && !previousIsPlaying

                    if isPlaying, trackChanged || playbackJustStarted {
                        await self.postTrackNotification(track)
                        self.lastNotifiedTrackId = track.id
                    }
                }

                previousTrack = currentTrack
                previousIsPlaying = isPlaying
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
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

    /// Whether the observation loop is actively running.
    var isObserving: Bool {
        if let task = self.observationTask {
            return !task.isCancelled
        }
        return false
    }

    func stopObserving() {
        self.observationTask?.cancel()
        self.observationTask = nil
    }
}
