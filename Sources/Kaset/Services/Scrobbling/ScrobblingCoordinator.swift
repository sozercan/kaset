import Foundation
import Observation

/// Bridges PlayerService to scrobbling backends.
/// Observes PlayerService playback mutations, tracks accumulated play time,
/// and triggers scrobbles when thresholds are met.
@MainActor
@Observable
final class ScrobblingCoordinator {
    // MARK: - Dependencies

    private let playerService: PlayerService
    private let settingsManager: SettingsManager
    /// All registered scrobbling service backends.
    let services: [any ScrobbleServiceProtocol]
    private let logger = DiagnosticsLogger.scrobbling

    /// The offline scrobble queue.
    let queue: ScrobbleQueue

    // MARK: - Tracking State

    /// The video ID of the track currently being tracked.
    private var currentTrackVideoId: String?

    /// Title of the track currently being tracked (for change detection when videoId is stale).
    private var currentTrackTitle: String?

    /// Artist of the track currently being tracked (for change detection when videoId is stale).
    private var currentTrackArtist: String?

    /// Snapshot of the tracked Song at the time tracking started (for finalization).
    private var trackedSong: Song?

    /// When the current track started playing (for scrobble timestamp).
    private var trackStartTime: Date?

    /// Accumulated play time in seconds (only counts actual playback).
    private var accumulatedPlayTime: TimeInterval = 0

    /// Last observed progress value (for detecting seeks/pauses).
    private var lastProgress: TimeInterval = 0

    /// Last time we recorded a progress update.
    private var lastProgressTime: Date?

    /// Whether this track has already been scrobbled.
    private var hasScrobbled = false

    /// Whether "now playing" has been sent for this track.
    private var hasSentNowPlaying = false

    // swiftformat:disable modifierOrder
    /// Queue flush task, cancelled in deinit.
    private var flushTask: Task<Void, Never>?

    /// Monotonic token that prevents stale flush tasks from clearing newer scheduled work.
    private var flushTaskGeneration = 0

    /// Now-playing tasks, cancelled in stopMonitoring/deinit.
    private var nowPlayingTasks: [Task<Void, Never>] = []
    // swiftformat:enable modifierOrder

    /// Whether the coordinator is actively monitoring.
    private(set) var isMonitoring = false

    /// Monotonic token used to ignore one-shot Observation callbacks armed before a stop/start cycle.
    private var monitoringGeneration = 0

    // MARK: - Init

    /// Creates a ScrobblingCoordinator.
    /// - Parameters:
    ///   - playerService: The player service to monitor.
    ///   - settingsManager: Settings manager for threshold configuration.
    ///   - services: Scrobbling service backends to fan out scrobbles to.
    ///   - queue: Persistent scrobble queue (injectable for testing).
    init(
        playerService: PlayerService,
        settingsManager: SettingsManager = .shared,
        services: [any ScrobbleServiceProtocol],
        queue: ScrobbleQueue = ScrobbleQueue()
    ) {
        self.playerService = playerService
        self.settingsManager = settingsManager
        self.services = services
        self.queue = queue
    }

    /// Note: Do not reference main actor properties here. All cleanup should be done in stopMonitoring().
    deinit {
        // All async tasks must be cancelled via stopMonitoring() before deinit.
    }

    // MARK: - Service Helpers

    /// Whether any registered service is both enabled in settings and connected.
    private var hasAnyEnabledConnectedService: Bool {
        self.services.contains { service in
            self.settingsManager.isServiceEnabled(service.serviceName) && service.authState.isConnected
        }
    }

    /// All services that are currently enabled in settings and authenticated.
    private var enabledConnectedServices: [any ScrobbleServiceProtocol] {
        self.services.filter { service in
            self.settingsManager.isServiceEnabled(service.serviceName) && service.authState.isConnected
        }
    }

    // MARK: - Lifecycle

    /// Must be called before deinit to ensure all async tasks are cancelled on the main actor.
    /// Starts monitoring PlayerService for scrobble-worthy events.
    func startMonitoring() {
        guard !self.isMonitoring else { return }
        self.isMonitoring = true
        self.monitoringGeneration += 1
        let generation = self.monitoringGeneration
        self.logger.info("Scrobbling coordinator started monitoring")

        self.observePlayerStateChanges(generation: generation)
        self.observeMonitoringEligibilityChanges(generation: generation)
        self.pollPlayerState()
        self.scheduleQueueFlushIfNeeded()
    }

    /// Stops monitoring and cancels all tasks.
    func stopMonitoring() {
        self.monitoringGeneration += 1
        self.flushTaskGeneration += 1
        self.flushTask?.cancel()
        self.flushTask = nil
        self.nowPlayingTasks.forEach { $0.cancel() }
        self.nowPlayingTasks.removeAll()
        self.isMonitoring = false
        self.logger.info("Scrobbling coordinator stopped monitoring")
    }

    /// Restores authentication state from persistent storage on app launch.
    func restoreAuthState() {
        for service in self.services {
            service.restoreSession()
        }
    }

    // MARK: - Observation

    /// Re-arms Observation tracking for playback fields that affect scrobbling.
    ///
    /// Progress updates already arrive from the playback WebView while media is playing, so observing those
    /// mutations avoids an independent app-lifetime 500 ms timer when the app is idle or scrobbling is disabled.
    private func observePlayerStateChanges(generation: Int) {
        guard self.isMonitoring(generation: generation) else { return }

        withObservationTracking {
            _ = self.playerService.currentTrack?.videoId
            _ = self.playerService.currentTrack?.title
            _ = self.playerService.currentTrack?.artistsDisplay
            _ = self.playerService.isPlaying
            _ = self.playerService.progress
            _ = self.playerService.duration
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isMonitoring(generation: generation) else { return }
                self.pollPlayerState()
                self.observePlayerStateChanges(generation: generation)
            }
        }
    }

    /// Re-arms Observation tracking for service auth/enablement. When no service is eligible, playback
    /// observation remains cheap and `pollPlayerState()` returns immediately; queue flushes are unscheduled.
    private func observeMonitoringEligibilityChanges(generation: Int) {
        guard self.isMonitoring(generation: generation) else { return }

        withObservationTracking {
            for service in self.services {
                _ = self.settingsManager.isServiceEnabled(service.serviceName)
                _ = service.authState
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isMonitoring(generation: generation) else { return }
                self.pollPlayerState()
                self.scheduleQueueFlushIfNeeded()
                self.observeMonitoringEligibilityChanges(generation: generation)
            }
        }
    }

    private func isMonitoring(generation: Int) -> Bool {
        self.isMonitoring && self.monitoringGeneration == generation
    }

    /// Core scrobbling logic — driven by observed playback mutations instead of a periodic timer.
    private func pollPlayerState() {
        // Skip if no service is both enabled and connected
        guard self.hasAnyEnabledConnectedService else { return }

        let currentTrack = self.playerService.currentTrack
        let isPlaying = self.playerService.isPlaying
        let progress = self.playerService.progress
        let duration = self.playerService.duration

        // Track change detection
        if let track = currentTrack {
            let videoIdChanged = track.videoId != self.currentTrackVideoId
            // Also detect by title/artist for natural transitions where videoId is stale
            let metadataChanged = self.currentTrackVideoId != nil
                && (track.title != self.currentTrackTitle || track.artistsDisplay != self.currentTrackArtist)

            if videoIdChanged || metadataChanged {
                // Track changed — finalize previous, start tracking new
                self.finalizeCurrentTrack()
                self.startTrackingNewTrack(track)
            } else if track.videoId == self.currentTrackVideoId,
                      self.hasScrobbled,
                      progress < self.lastProgress - 5.0
            {
                // Same track but progress jumped backward significantly — replay detected
                self.finalizeCurrentTrack()
                self.startTrackingNewTrack(track)
            }

            // Accumulate play time (only when playing)
            if isPlaying {
                self.accumulatePlayTime(progress: progress)
            } else {
                // Reset progress tracking when paused
                self.lastProgressTime = nil
            }

            // Send "now playing" once per track
            if !self.hasSentNowPlaying, isPlaying {
                self.sendNowPlaying(track)
            }

            // Check scrobble threshold
            if !self.hasScrobbled, duration > 0 {
                self.checkScrobbleThreshold(track: track, duration: duration)
            }
        } else if self.currentTrackVideoId != nil {
            // Track was cleared
            self.finalizeCurrentTrack()
        }
    }

    // MARK: - Track Lifecycle

    private func startTrackingNewTrack(_ track: Song) {
        self.currentTrackVideoId = track.videoId
        self.currentTrackTitle = track.title
        self.currentTrackArtist = track.artistsDisplay
        self.trackedSong = track
        self.trackStartTime = Date()
        self.accumulatedPlayTime = 0
        self.lastProgress = self.playerService.progress
        self.lastProgressTime = Date()
        self.hasScrobbled = false
        self.hasSentNowPlaying = false
        self.logger.debug("Started tracking: \(track.title) by \(track.artistsDisplay)")
    }

    private func finalizeCurrentTrack() {
        // Nothing to finalize if no track was being tracked
        guard self.currentTrackVideoId != nil else { return }

        // Final threshold check before discarding accumulated play time
        if !self.hasScrobbled, let song = self.trackedSong {
            let duration = song.duration ?? self.playerService.duration
            if duration > 0 {
                self.checkScrobbleThreshold(track: song, duration: duration)
            }
        }

        self.logger.debug("Finalized track (accumulated: \(String(format: "%.1f", self.accumulatedPlayTime))s, scrobbled: \(self.hasScrobbled))")

        // Reset tracking state
        self.currentTrackVideoId = nil
        self.currentTrackTitle = nil
        self.currentTrackArtist = nil
        self.trackedSong = nil
        self.trackStartTime = nil
        self.accumulatedPlayTime = 0
        self.lastProgress = 0
        self.lastProgressTime = nil
        self.hasScrobbled = false
        self.hasSentNowPlaying = false
    }

    // MARK: - Play Time Accumulation

    private func accumulatePlayTime(progress: TimeInterval) {
        guard let lastTime = self.lastProgressTime else {
            self.lastProgress = progress
            self.lastProgressTime = Date()
            return
        }

        let now = Date()
        let wallClockDelta = now.timeIntervalSince(lastTime)
        let progressDelta = progress - self.lastProgress

        // Only count positive, small deltas (< 2s wall clock) to ignore seeks
        // A normal playback progress update should show ~1s or less of progress.
        if progressDelta > 0, progressDelta < 2.0, wallClockDelta < 2.0 {
            self.accumulatedPlayTime += progressDelta
        }

        self.lastProgress = progress
        self.lastProgressTime = now
    }

    // MARK: - Scrobble Threshold

    private func checkScrobbleThreshold(track: Song, duration: TimeInterval) {
        // Last.fm requires tracks to be at least 30 seconds long
        guard duration >= 30 else { return }

        let percentThreshold = self.settingsManager.scrobblePercentThreshold
        let minSeconds = self.settingsManager.scrobbleMinSeconds

        // Scrobble when: accumulatedPlayTime >= duration * threshold OR >= minSeconds
        let thresholdMet: Bool = if duration > 0 {
            self.accumulatedPlayTime >= duration * percentThreshold
                || self.accumulatedPlayTime >= minSeconds
        } else {
            self.accumulatedPlayTime >= minSeconds
        }

        if thresholdMet {
            self.hasScrobbled = true

            guard let startTime = self.trackStartTime else { return }

            let scrobbleTrack = ScrobbleTrack(from: track, timestamp: startTime)
            self.queue.enqueue(scrobbleTrack)
            self.scheduleQueueFlushIfNeeded()
            self.logger.info("Scrobble threshold met for: \(track.title) (accumulated: \(String(format: "%.1f", self.accumulatedPlayTime))s)")
        }
    }

    // MARK: - Now Playing

    private func sendNowPlaying(_ track: Song) {
        self.hasSentNowPlaying = true

        guard let startTime = self.trackStartTime else { return }

        let scrobbleTrack = ScrobbleTrack(from: track, timestamp: startTime)

        // Cancel any in-flight now-playing tasks from a previous track
        self.nowPlayingTasks.forEach { $0.cancel() }
        self.nowPlayingTasks.removeAll()

        // Send now-playing to all enabled+connected services
        for service in self.enabledConnectedServices {
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await service.updateNowPlaying(scrobbleTrack)
                } catch is CancellationError {
                    // Expected when coordinator stops or track changes
                } catch {
                    self.logger.debug("Now playing update failed for \(service.serviceName) (non-critical): \(error.localizedDescription)")
                }
            }
            self.nowPlayingTasks.append(task)
        }
    }

    // MARK: - Queue Flush

    private func scheduleQueueFlushIfNeeded(after delay: Duration = .seconds(30)) {
        guard self.isMonitoring,
              self.hasAnyEnabledConnectedService,
              !self.queue.isEmpty
        else {
            self.flushTaskGeneration += 1
            self.flushTask?.cancel()
            self.flushTask = nil
            return
        }

        guard self.flushTask == nil || self.flushTask?.isCancelled == true else { return }

        self.flushTaskGeneration += 1
        let generation = self.flushTaskGeneration
        self.flushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                guard let self, self.flushTaskGeneration == generation else { return }
                self.flushTask = nil
                return
            }

            guard let self, self.isMonitoring, self.flushTaskGeneration == generation else { return }
            await self.flushQueue()
            guard self.isMonitoring, self.flushTaskGeneration == generation else { return }
            self.flushTask = nil
            self.scheduleQueueFlushIfNeeded()
        }
    }

    /// Exposed for focused tests; true only when there is pending queue work eligible for a one-shot flush.
    var isQueueFlushScheduled: Bool {
        guard let flushTask else { return false }
        return !flushTask.isCancelled
    }

    /// Flushes pending scrobbles from the queue to all enabled services.
    /// Services deduplicate naturally (e.g., Last.fm ignores duplicate artist+track+timestamp).
    func flushQueue() async {
        guard self.hasAnyEnabledConnectedService else { return }
        guard !self.queue.isEmpty else { return }

        // Prune expired entries first
        self.queue.pruneExpired()

        let batch = self.queue.dequeue(limit: 50)
        guard !batch.isEmpty else { return }

        self.logger.debug("Flushing \(batch.count) scrobbles from queue")

        // Submit to all enabled+connected services. Services deduplicate, so
        // re-submitting to a service that already accepted is safe (Option A).
        var acceptedIds = Set<UUID>()

        for service in self.enabledConnectedServices {
            do {
                let results = try await service.scrobble(batch)

                let accepted = results.filter(\.accepted)
                if !accepted.isEmpty {
                    acceptedIds.formUnion(accepted.map(\.track.id))
                    self.logger.info("Flushed \(accepted.count)/\(batch.count) scrobbles to \(service.serviceName)")
                }

                // Log rejected scrobbles
                let rejected = results.filter { !$0.accepted }
                for result in rejected {
                    self.logger.warning("Scrobble rejected by \(service.serviceName): \(result.track.title) - \(result.errorMessage ?? "unknown reason")")
                }
            } catch is CancellationError {
                return
            } catch let error as ScrobbleError {
                switch error {
                case .rateLimited:
                    self.logger.warning("\(service.serviceName) rate limited during flush, will retry next cycle")
                case .sessionExpired:
                    self.logger.warning("\(service.serviceName) session expired during flush, scrobbles kept in queue")
                default:
                    self.logger.error("\(service.serviceName) flush failed: \(error.localizedDescription)")
                }
            } catch {
                self.logger.error("\(service.serviceName) flush failed with unexpected error: \(error.localizedDescription)")
            }
        }

        // Only mark accepted tracks as completed; rejected tracks remain in the queue for retry.
        if !acceptedIds.isEmpty {
            self.queue.markCompleted(acceptedIds)
        }
    }
}
