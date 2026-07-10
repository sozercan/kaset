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

    /// Provider that owns the current item's sub-track breakdown. Optional because it requires a
    /// YouTubeClient, which may not be available in all contexts. Read-only here: the coordinator
    /// consumes the tracklist for per-sub-track scrobbling but never fetches it.
    private let nowPlayingTracklistProvider: NowPlayingTracklistProvider?

    // MARK: - Tracking State

    /// The video ID of the track currently being tracked.
    private var currentTrackVideoId: String?

    /// Title of the track currently being tracked (for change detection when videoId is stale).
    private var currentTrackTitle: String?

    /// Artist of the track currently being tracked (for change detection when videoId is stale).
    private var currentTrackArtist: String?

    /// Snapshot of the tracked Song at the time tracking started (for finalization).
    private var trackedSong: Song?

    /// Play-time state machine for the whole track (single-track mode). Nil when nothing is tracked.
    private var trackTracker: PlaybackScrobbleTracker?

    // MARK: - Mix-Mode State

    /// Tracklist for the current mix, if one was found. When non-nil, the coordinator operates in
    /// mix-mode (per-sub-track scrobbling). Sourced from the shared provider — the coordinator does
    /// not fetch it, so mix detection runs even when scrobbling is idle.
    private var mixTracklist: MixTracklist? {
        self.nowPlayingTracklistProvider?.tracklist
    }

    /// Snapshot of the tracked item's tracklist, captured while it is the current video. Finalize and
    /// per-sub-track handling read this rather than the live provider: `PlayerService.currentTrack`'s
    /// synchronous `didSet` resets the provider to the *incoming* video the instant a track changes,
    /// which is before this coordinator's Observation-driven poll finalizes the *outgoing* one. Reading
    /// the live provider during finalize would therefore see the wrong video and skip the outgoing
    /// track's final scrobble check.
    private var trackedMixTracklist: MixTracklist?

    /// The sub-track currently being tracked within the mix.
    private var currentMixEntry: MixTrackEntry?

    /// Play-time state machine for the current mix sub-track. Nil between entries.
    private var mixEntryTracker: PlaybackScrobbleTracker?

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
    ///   - nowPlayingTracklistProvider: Shared source of the current item's sub-track breakdown (optional).
    init(
        playerService: PlayerService,
        settingsManager: SettingsManager = .shared,
        services: [any ScrobbleServiceProtocol],
        queue: ScrobbleQueue = ScrobbleQueue(),
        nowPlayingTracklistProvider: NowPlayingTracklistProvider? = nil
    ) {
        self.playerService = playerService
        self.settingsManager = settingsManager
        self.services = services
        self.queue = queue
        self.nowPlayingTracklistProvider = nowPlayingTracklistProvider
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
                      let tracker = self.trackTracker, tracker.hasScrobbled,
                      progress < tracker.lastProgress - 5.0
            {
                // Same track but progress jumped backward significantly — replay detected
                self.finalizeCurrentTrack()
                self.startTrackingNewTrack(track)
            }

            // Cache the tracklist while we're on the tracked video, then drive mix-mode from that
            // snapshot. This keeps finalization of the outgoing track correct even after the provider
            // has already reset to the next video (see `trackedMixTracklist`). The guard never
            // overwrites a cached tracklist with nil, so a late-arriving fetch latches once.
            if track.videoId == self.currentTrackVideoId, let live = self.mixTracklist {
                self.trackedMixTracklist = live
            }
            if let tracklist = self.trackedMixTracklist {
                self.handleMixPlayback(track: track, tracklist: tracklist, progress: progress, isPlaying: isPlaying)
                return
            }

            // Accumulate play time (the tracker ignores seeks and paused spans internally)
            self.trackTracker?.accumulate(progress: progress, isPlaying: isPlaying, now: Date())

            // Send "now playing" once per track
            if self.trackTracker?.hasSentNowPlaying == false, isPlaying {
                self.sendNowPlaying(track)
            }

            // Check scrobble threshold. Deferred while the provider's tracklist parse is in
            // flight so a slow fetch can't let the whole mix scrobble once as one track and
            // again per sub-track after the tracklist arrives.
            if self.trackTracker?.hasScrobbled == false, duration > 0,
               self.nowPlayingTracklistProvider?.isParsing != true
            {
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
        self.trackTracker = PlaybackScrobbleTracker(
            startTime: Date(),
            initialProgress: self.playerService.progress
        )

        // Reset mix-entry tracking for the new track. The tracklist snapshot starts empty and is
        // (re)captured from the provider on subsequent polls, once the async fetch for this video
        // resolves.
        self.currentMixEntry = nil
        self.mixEntryTracker = nil
        self.trackedMixTracklist = nil

        self.logger.debug("Started tracking: \(track.title) by \(track.artistsDisplay)")
    }

    private func finalizeCurrentTrack() {
        // Finalize mix-mode sub-track if active. Uses the snapshot, not the live provider, which has
        // already been reset to the incoming video by the time this runs on a track change.
        if self.trackedMixTracklist != nil, let entry = self.currentMixEntry {
            self.finalizeMixEntry(entry, song: self.trackedSong)
        }

        // Nothing to finalize if no track was being tracked
        guard self.currentTrackVideoId != nil else { return }

        // Final threshold check before discarding accumulated play time (single-track mode only)
        if self.trackedMixTracklist == nil, self.trackTracker?.hasScrobbled == false, let song = self.trackedSong {
            let duration = song.duration ?? self.playerService.duration
            if duration > 0 {
                self.checkScrobbleThreshold(track: song, duration: duration)
            }
        }

        self.logger.debug("Finalized track (accumulated: \(String(format: "%.1f", self.trackTracker?.accumulatedPlayTime ?? 0))s, scrobbled: \(self.trackTracker?.hasScrobbled ?? false))")

        // Reset tracking state
        self.currentTrackVideoId = nil
        self.currentTrackTitle = nil
        self.currentTrackArtist = nil
        self.trackedSong = nil
        self.trackTracker = nil

        // Reset mix-entry tracking. The tracklist is the provider's, keyed on video id.
        self.currentMixEntry = nil
        self.mixEntryTracker = nil
        self.trackedMixTracklist = nil
    }

    // MARK: - Scrobble Threshold

    /// Scrobble thresholds for a whole track. Whole tracks always carry a duration, so an
    /// unknown duration is treated as ineligible.
    private var trackThresholds: PlaybackScrobbleTracker.Thresholds {
        .init(
            percent: self.settingsManager.scrobblePercentThreshold,
            minSeconds: self.settingsManager.scrobbleMinSeconds,
            allowsUnknownDuration: false
        )
    }

    /// Scrobble thresholds for a mix sub-track. YouTube does not always expose chapter bounds,
    /// so an unknown duration still qualifies via `minSeconds`.
    private var mixEntryThresholds: PlaybackScrobbleTracker.Thresholds {
        .init(
            percent: self.settingsManager.scrobblePercentThreshold,
            minSeconds: self.settingsManager.scrobbleMinSeconds,
            allowsUnknownDuration: true
        )
    }

    private func checkScrobbleThreshold(track: Song, duration: TimeInterval) {
        guard var tracker = self.trackTracker,
              tracker.meetsThreshold(duration: duration, thresholds: self.trackThresholds)
        else { return }

        tracker.markScrobbled()
        self.trackTracker = tracker

        let scrobbleTrack = ScrobbleTrack(from: track, timestamp: tracker.startTime)
        self.queue.enqueue(scrobbleTrack)
        self.scheduleQueueFlushIfNeeded()
        self.logger.info("Scrobble threshold met for: \(track.title) (accumulated: \(String(format: "%.1f", tracker.accumulatedPlayTime))s)")
    }

    // MARK: - Mix-Mode Playback Handling

    /// Handles per-sub-track scrobbling within a mix. Called instead of the
    /// single-track accumulation/threshold logic when a mix tracklist is available.
    private func handleMixPlayback(
        track: Song,
        tracklist: MixTracklist,
        progress: TimeInterval,
        isPlaying: Bool
    ) {
        // Determine the sub-track at the current playback position
        let entry = tracklist.entry(at: progress)

        // Sub-track changed — finalize previous, start new
        if entry?.id != self.currentMixEntry?.id {
            if let prevEntry = self.currentMixEntry {
                self.finalizeMixEntry(prevEntry, song: track)
            }

            if let entry {
                self.startMixEntry(entry, progress: progress)
            } else {
                // Between entries or before the first — clear current
                self.currentMixEntry = nil
            }
        }

        guard let entry, self.currentMixEntry?.id == entry.id else { return }

        // Seek detection: a significant jump resets the sub-track clock. Once the entry has
        // scrobbled, only a backward jump matters — that's a replay, restarted with a fresh
        // tracker so a second scrobble carries a new timestamp instead of duplicating the first.
        if let tracker = self.mixEntryTracker, abs(progress - tracker.lastProgress) > 5.0 {
            if tracker.hasScrobbled {
                if progress < tracker.lastProgress {
                    self.startMixEntry(entry, progress: progress)
                    self.logger.debug("Mix replay detected at \(String(format: "%.1f", progress))s, restarting sub-track '\(entry.title)'")
                }
            } else {
                self.mixEntryTracker?.resetForSeek()
                self.logger.debug("Mix seek detected at \(String(format: "%.1f", progress))s, resetting sub-track '\(entry.title)'")
            }
        }

        // Accumulate play time (the tracker ignores seeks and paused spans internally)
        self.mixEntryTracker?.accumulate(progress: progress, isPlaying: isPlaying, now: Date())

        // Send "now playing" once per sub-track
        if self.mixEntryTracker?.hasSentNowPlaying == false, isPlaying {
            self.sendMixNowPlaying(entry, song: track)
        }

        // Check sub-track scrobble threshold
        if self.mixEntryTracker?.hasScrobbled == false {
            self.checkMixEntryScrobbleThreshold(entry: entry, song: track)
        }
    }

    /// Starts tracking a new sub-track within the mix.
    private func startMixEntry(_ entry: MixTrackEntry, progress: TimeInterval) {
        self.currentMixEntry = entry
        self.mixEntryTracker = PlaybackScrobbleTracker(startTime: Date(), initialProgress: progress)
        self.logger.debug("Mix sub-track started: \(entry.artist ?? "?") - \(entry.title) at \(String(format: "%.1f", entry.startTime))s")
    }

    /// Finalizes a mix sub-track — checks threshold and scrobbles if met.
    private func finalizeMixEntry(_ entry: MixTrackEntry, song: Song?) {
        // Final threshold check before the sub-track ends (skip if it already scrobbled)
        if self.mixEntryTracker?.hasScrobbled == false {
            self.checkMixEntryScrobbleThreshold(entry: entry, song: song)
        }

        self.logger.debug("Mix sub-track finalized: \(entry.artist ?? "?") - \(entry.title) (accumulated: \(String(format: "%.1f", self.mixEntryTracker?.accumulatedPlayTime ?? 0))s, scrobbled: \(self.mixEntryTracker?.hasScrobbled ?? false))")

        self.currentMixEntry = nil
        self.mixEntryTracker = nil
    }

    /// Checks whether the current sub-track has met the scrobble threshold.
    private func checkMixEntryScrobbleThreshold(entry: MixTrackEntry, song: Song?) {
        guard var tracker = self.mixEntryTracker,
              tracker.meetsThreshold(duration: entry.duration, thresholds: self.mixEntryThresholds)
        else { return }

        tracker.markScrobbled()
        self.mixEntryTracker = tracker

        let scrobbleTrack = ScrobbleTrack(
            title: entry.title,
            artist: entry.artist ?? song?.artistsDisplay ?? "Unknown Artist",
            album: nil,
            duration: entry.duration,
            timestamp: tracker.startTime,
            videoId: song?.videoId
        )
        self.queue.enqueue(scrobbleTrack)
        self.scheduleQueueFlushIfNeeded()
        self.logger.info("Mix scrobble: \(entry.artist ?? "?") - \(entry.title) (accumulated: \(String(format: "%.1f", tracker.accumulatedPlayTime))s)")
    }

    /// Sends a "now playing" update for a mix sub-track.
    private func sendMixNowPlaying(_ entry: MixTrackEntry, song: Song) {
        guard var tracker = self.mixEntryTracker else { return }
        tracker.markNowPlayingSent()
        self.mixEntryTracker = tracker

        let scrobbleTrack = ScrobbleTrack(
            title: entry.title,
            artist: entry.artist ?? song.artistsDisplay,
            album: nil,
            duration: entry.duration,
            timestamp: tracker.startTime,
            videoId: song.videoId
        )

        // Cancel any in-flight now-playing tasks from a previous sub-track
        self.nowPlayingTasks.forEach { $0.cancel() }
        self.nowPlayingTasks.removeAll()

        for service in self.enabledConnectedServices {
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await service.updateNowPlaying(scrobbleTrack)
                } catch is CancellationError {
                    // Expected when sub-track changes
                } catch {
                    self.logger.debug("Mix now playing failed for \(service.serviceName) (non-critical): \(error.localizedDescription)")
                }
            }
            self.nowPlayingTasks.append(task)
        }
    }

    // MARK: - Now Playing

    private func sendNowPlaying(_ track: Song) {
        guard var tracker = self.trackTracker else { return }
        tracker.markNowPlayingSent()
        self.trackTracker = tracker

        let scrobbleTrack = ScrobbleTrack(from: track, timestamp: tracker.startTime)

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
