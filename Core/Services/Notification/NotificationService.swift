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
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert])
                self.logger.info("Notification authorization: \(granted)")
            } catch {
                self.logger.error("Notification authorization failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Observation

    private func startObserving() {
        self.observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var previousTrack: Song?

            while !Task.isCancelled {
                let currentTrack = self.playerService.currentTrack

                // Only notify on actual track changes with valid title
                if let track = currentTrack,
                   track.id != previousTrack?.id,
                   track.id != self.lastNotifiedTrackId,
                   track.title != "Loading..."
                {
                    await self.postTrackNotification(track)
                    self.lastNotifiedTrackId = track.id
                }

                previousTrack = currentTrack
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: - Notification

    private func postTrackNotification(_ track: Song) async {
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
