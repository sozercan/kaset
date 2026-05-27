import AppKit
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
        if let attachment = await self.artworkAttachment(for: track) {
            content.attachments = [attachment]
        }

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

    private func artworkAttachment(for track: Song) async -> UNNotificationAttachment? {
        for url in Self.artworkURLs(for: track) {
            guard let image = await ImageCache.shared.image(for: url, targetSize: .init(width: 512, height: 512)),
                  let pngData = Self.pngData(from: image)
            else {
                continue
            }

            do {
                let attachmentURL = try Self.writeArtworkAttachment(pngData, trackId: track.id)
                return try UNNotificationAttachment(identifier: "artwork-\(track.id)", url: attachmentURL)
            } catch {
                self.logger.debug("Failed to prepare notification artwork: \(error.localizedDescription, privacy: .public)")
            }
        }

        return nil
    }

    static func artworkURLs(for track: Song) -> [URL] {
        var urls: [URL] = []
        if let primary = track.thumbnailURL?.highQualityThumbnailURL {
            urls.append(primary)
        }
        if let fallback = track.fallbackThumbnailURL,
           !urls.contains(fallback)
        {
            urls.append(fallback)
        }
        return urls
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    private static func writeArtworkAttachment(_ data: Data, trackId: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KasetNotificationArtwork", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename = trackId
            .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        let url = directory.appendingPathComponent("\(filename).png")
        try data.write(to: url, options: .atomic)
        return url
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
