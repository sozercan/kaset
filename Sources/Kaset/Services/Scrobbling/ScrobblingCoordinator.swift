import Foundation
import Observation

/// Bridges PlayerService playback mutations to scrobbling backends.
@MainActor
@Observable
final class ScrobblingCoordinator {
    static let mixMinimumVideoDuration: TimeInterval = 600
    static let mixReplayStartTolerance: TimeInterval = 5

    // MARK: - Dependencies

    let playerService: PlayerService
    private let settingsManager: any ScrobblingSettingsProviding
    /// All registered scrobbling service backends.
    let services: [any ScrobbleServiceProtocol]
    let logger = DiagnosticsLogger.scrobbling

    /// The offline scrobble queue.
    let queue: ScrobbleQueue

    /// Optional mix-tracklist parser; requires a YouTubeClient that some contexts do not provide.
    let mixTracklistParser: MixTracklistParser?
    let unknownDurationParseDelay: Duration
    let mixParseTimeout: Duration
    private let now: () -> Date

    // MARK: - Tracking State

    /// The video ID of the track currently being tracked.
    var currentTrackVideoId: String?

    /// Title of the track currently being tracked (for change detection when videoId is stale).
    private var currentTrackTitle: String?

    /// Artist of the track currently being tracked (for change detection when videoId is stale).
    private var currentTrackArtist: String?
    var requiredPlaybackStateSequence: Int?

    /// Snapshot of the tracked Song at the time tracking started (for finalization).
    var trackedSong: Song?

    /// Play-time state machine for the whole track (single-track mode). Nil when nothing is tracked.
    var trackTracker: PlaybackScrobbleTracker?
    var pendingWholeTrackPlays: [PendingWholeTrackPlay] = []

    /// Tracked-video duration retained across transitions so finalization never reads the next track.
    var trackedVideoDuration: TimeInterval?

    // MARK: - Mix-Mode State

    /// Classification gate that defers whole-track side effects until mix detection resolves.
    var mixDetectionState: MixDetectionState = .unresolved

    /// The sub-track currently being tracked within the mix.
    private var currentMixEntry: MixTrackEntry?

    /// Play-time state machine for the current mix sub-track. Nil between entries.
    var mixEntryTracker: PlaybackScrobbleTracker?
    var mixEntryScrobbledIds: Set<UUID> = []

    /// In-flight tracklist parse and its current-track result monitor.
    var mixParseTask: Task<MixTracklist?, Never>?
    var mixParseMonitorTask: Task<Void, Never>?
    var mixParseTimeoutTask: Task<Void, Never>?
    var unknownDurationParseTask: Task<Void, Never>?
    var durationConfirmationTask: Task<Void, Never>?
    var durationConfirmationCompleted = false
    var mixParseStartedWithoutDuration = false

    /// Monotonic token preventing a cancelled/stale parse from clearing or applying newer work.
    var mixParseGeneration = 0

    /// Eligible ended tracks whose parse may safely finish off the current-track path.
    var pendingMixFinalizations: [UUID: PendingMixFinalization] = [:]

    /// Verified progress ranges retained until delayed chapter metadata can credit real sub-tracks.
    var provisionalMixHistory = ProvisionalMixPlaybackHistory()
    var provisionalCurrentMixCredit: (entryId: UUID, credit: ProvisionalMixPlaybackHistory.Credit)?

    var currentMixTracklist: MixTracklist? {
        guard case let .mix(tracklist) = self.mixDetectionState else { return nil }
        return tracklist
    }

    // swiftformat:disable modifierOrder
    /// Queue flush task, cancelled in deinit.
    private var flushTask: Task<Void, Never>?

    /// Monotonic token that prevents stale flush tasks from clearing newer scheduled work.
    private var flushTaskGeneration = 0

    /// Now-playing tasks, cancelled in stopMonitoring/deinit.
    var nowPlayingTasks: [Task<Void, Never>] = []
    // swiftformat:enable modifierOrder

    /// Whether the coordinator is actively monitoring.
    private(set) var isMonitoring = false

    /// Monotonic token used to ignore one-shot Observation callbacks armed before a stop/start cycle.
    private var monitoringGeneration = 0

    // MARK: - Init

    /// Creates a ScrobblingCoordinator with injectable services, settings, queue, and mix parser.
    init(
        playerService: PlayerService,
        settingsManager: any ScrobblingSettingsProviding = SettingsManager.shared,
        services: [any ScrobbleServiceProtocol],
        queue: ScrobbleQueue = ScrobbleQueue(),
        mixTracklistParser: MixTracklistParser? = nil,
        unknownDurationParseDelay: Duration = .seconds(2),
        mixParseTimeout: Duration = .seconds(10),
        now: @escaping () -> Date = Date.init
    ) {
        self.playerService = playerService
        self.settingsManager = settingsManager
        self.services = services
        self.queue = queue
        self.mixTracklistParser = mixTracklistParser
        self.unknownDurationParseDelay = unknownDurationParseDelay
        self.mixParseTimeout = mixParseTimeout
        self.now = now
    }

    /// Permanent teardown must call stopMonitoring(finalizeCurrentTrack: true) first.
    deinit {
        // Main-actor state cannot be safely finalized from deinit.
    }

    // MARK: - Service Helpers

    /// Whether any registered service is both enabled in settings and connected.
    private var hasAnyEnabledConnectedService: Bool {
        self.services.contains { service in
            self.settingsManager.isServiceEnabled(service.serviceName) && service.authState.isConnected
        }
    }

    /// All services that are currently enabled in settings and authenticated.
    var enabledConnectedServices: [any ScrobbleServiceProtocol] {
        self.services.filter { service in
            self.settingsManager.isServiceEnabled(service.serviceName) && service.authState.isConnected
        }
    }

    // MARK: - Lifecycle

    /// Starts monitoring; must be paired with stopMonitoring() before deinit.
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

    /// Stops active monitoring. Set `finalizeCurrentTrack` only for permanent teardown.
    func stopMonitoring(finalizeCurrentTrack: Bool = false) {
        if finalizeCurrentTrack {
            self.finalizeCurrentTrack()
        }
        self.monitoringGeneration += 1
        self.flushTaskGeneration += 1
        self.flushTask?.cancel()
        self.flushTask = nil
        self.cancelMixTracklistFetch()
        if case .parsing = self.mixDetectionState {
            self.mixDetectionState = .unresolved
        }
        self.cancelNowPlayingTasks()
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

    /// Re-arms observation for playback fields, avoiding an independent app-lifetime polling timer.
    private func observePlayerStateChanges(generation: Int) {
        guard self.isMonitoring(generation: generation) else { return }

        withObservationTracking {
            _ = self.playerService.currentTrack?.videoId
            _ = self.playerService.currentTrack?.title
            _ = self.playerService.currentTrack?.artistsDisplay
            _ = self.playerService.isPlaying
            _ = self.playerService.progress
            _ = self.playerService.duration
            _ = self.playerService.playbackStateVideoId
            _ = self.playerService.playbackStateObservationSequence
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isMonitoring(generation: generation) else { return }
                self.pollPlayerState()
                self.observePlayerStateChanges(generation: generation)
            }
        }
    }

    /// Re-arms service eligibility observation and unschedules queue work when none is active.
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
    func pollPlayerState() {
        // Skip if no service is both enabled and connected
        guard self.hasAnyEnabledConnectedService else { return }

        let currentTrack = self.playerService.currentTrack
        let isPlaying = self.playerService.isPlaying
        let progress = self.playerService.progress

        // Track change detection
        if let track = currentTrack {
            let videoIdChanged = track.videoId != self.currentTrackVideoId
            // Also detect by title/artist for natural transitions where videoId is stale
            let metadataChanged = self.currentTrackVideoId != nil
                && (track.title != self.currentTrackTitle || track.artistsDisplay != self.currentTrackArtist)

            if videoIdChanged || metadataChanged {
                // Track changed — finalize previous, start tracking new
                let requiredPlaybackStateSequence = metadataChanged && !videoIdChanged
                    ? self.playerService.playbackStateObservationSequence &+ 1
                    : nil
                self.finalizeCurrentTrack()
                self.startTrackingNewTrack(
                    track,
                    requiredPlaybackStateSequence: requiredPlaybackStateSequence
                )
            }

            guard self.acceptPlaybackState(for: track) else { return }
            self.updateTrackedVideoDuration(for: track)
            self.revalidatePendingWholeTrackLatchIfNeeded()

            if track.videoId == self.currentTrackVideoId,
               let tracker = self.trackTracker, tracker.hasScrobbled,
               progress < tracker.lastProgress - 5.0
            {
                switch self.mixDetectionState {
                case .notMix:
                    self.finalizeCurrentTrack()
                    self.startTrackingNewTrack(track)
                case .unresolved, .parsing, .awaitingDuration:
                    self.refreshPendingWholeTrackPlay(with: tracker)
                    self.trackTracker = PlaybackScrobbleTracker(startTime: self.now(), initialProgress: progress)
                case .mix:
                    break
                }
            }

            // Resolve whether this is a regular track or a mix. Duration is often unknown at
            // track-start, so unresolved/parsing states keep provisional play time but suppress
            // whole-track now-playing/scrobble side effects until classification completes.
            self.resolveMixDetection(for: track)
            switch self.mixDetectionState {
            case .unresolved, .parsing, .awaitingDuration:
                // Provisional whole-track accounting intentionally matches regular-track behavior:
                // `accumulate` rejects the seek delta but preserves verified play time on both sides.
                self.accumulateWholeTrack(
                    progress: progress,
                    isPlaying: isPlaying,
                    recordProvisionalSegment: true
                )
                self.capturePendingWholeTrackScrobbleIfNeeded(track)
                if case .awaitingDuration = self.mixDetectionState,
                   self.durationConfirmationCompleted,
                   self.trackTracker?.hasSentNowPlaying == false,
                   isPlaying
                {
                    self.sendNowPlaying(track)
                }
                return
            case let .mix(tracklist):
                self.consumeProvisionalPlayback(for: tracklist, song: self.trackedSong)
                self.handleMixPlayback(track: track, tracklist: tracklist, progress: progress, isPlaying: isPlaying)
                return
            case .notMix:
                break
            }

            // Accumulate play time (the tracker ignores seeks and paused spans internally)
            self.accumulateWholeTrack(
                progress: progress,
                isPlaying: isPlaying,
                recordProvisionalSegment: false
            )

            // Send "now playing" once per track
            if self.trackTracker?.hasSentNowPlaying == false, isPlaying {
                self.sendNowPlaying(track)
            }

            // Check scrobble threshold
            if self.trackTracker?.hasScrobbled == false, let duration = self.trackedVideoDuration {
                self.checkScrobbleThreshold(track: track, duration: duration)
            }
        } else if self.currentTrackVideoId != nil {
            // Track was cleared
            self.finalizeCurrentTrack()
        }
    }

    // MARK: - Track Lifecycle

    private func startTrackingNewTrack(
        _ track: Song,
        requiredPlaybackStateSequence: Int? = nil
    ) {
        self.currentTrackVideoId = track.videoId
        self.currentTrackTitle = track.title
        self.currentTrackArtist = track.artistsDisplay
        self.trackedSong = track
        self.trackTracker = PlaybackScrobbleTracker(
            startTime: self.now(),
            initialProgress: self.playerService.progress
        )
        self.requiredPlaybackStateSequence = requiredPlaybackStateSequence
        self.pendingWholeTrackPlays.removeAll()
        self.trackedVideoDuration = track.duration.flatMap { $0 > 0 ? $0 : nil }
        if requiredPlaybackStateSequence == nil {
            self.updateTrackedVideoDuration(for: track)
        }

        // Reset mix-mode state for the new track
        self.mixDetectionState = .unresolved
        self.currentMixEntry = nil
        self.mixEntryTracker = nil
        self.mixEntryScrobbledIds.removeAll()
        self.provisionalMixHistory.removeAll()
        self.provisionalCurrentMixCredit = nil
        self.durationConfirmationCompleted = false
        self.mixParseStartedWithoutDuration = false
        self.scheduleUnknownDurationParse(for: track)

        self.logger.debug("Started tracking: \(track.title) by \(track.artistsDisplay)")

        // Mix detection is gated on duration, which is often not yet known here. The poll loop
        // retries `resolveMixDetection(for:)` until duration is available.
    }

    /// Resolves long tracks through parsing and short/no-parser tracks as whole-track mode.
    private func resolveMixDetection(for track: Song) {
        let scopedDuration = self.scopedDuration(for: track)
        if case let .awaitingDuration(tracklist) = self.mixDetectionState {
            let phase: MixDurationDecisionPhase = self.durationConfirmationCompleted
                ? .activeAfterGrace
                : .activeBeforeGrace
            let decision = Self.mixDurationDecision(
                for: tracklist,
                songDuration: track.duration,
                playerDuration: self.scopedPlayerDuration(for: track),
                phase: phase
            )
            if self.applyMixDurationDecision(decision, tracklist: tracklist) {
                return
            }
            if !self.durationConfirmationCompleted, self.durationConfirmationTask == nil {
                self.scheduleAwaitingDurationConfirmation(for: track)
            }
            return
        }

        if case .parsing = self.mixDetectionState {
            if let songDuration = track.duration,
               songDuration > 0,
               songDuration <= Self.mixMinimumVideoDuration
            {
                self.cancelMixTracklistFetch()
                self.resolveAsNotMix()
            } else if let songDuration = track.duration,
                      songDuration > Self.mixMinimumVideoDuration,
                      self.mixParseStartedWithoutDuration
            {
                self.mixParseStartedWithoutDuration = false
            }
            return
        }

        guard case .unresolved = self.mixDetectionState else { return }
        guard let parser = self.mixTracklistParser else {
            self.resolveAsNotMix()
            return
        }
        guard let scopedDuration else {
            if self.unknownDurationParseTask == nil {
                self.scheduleUnknownDurationParse(for: track)
            }
            return
        }
        guard scopedDuration > Self.mixMinimumVideoDuration else {
            if let duration = track.duration, duration > 0 {
                self.resolveAsNotMix()
            } else if self.unknownDurationParseTask == nil {
                self.scheduleUnknownDurationParse(for: track)
            }
            return
        }

        let lacksSongDuration = track.duration.map { $0 <= 0 } ?? true
        self.startMixParse(for: track, parser: parser, startedWithoutDuration: lacksSongDuration)
    }

    func startMixParse(
        for track: Song,
        parser: MixTracklistParser,
        startedWithoutDuration: Bool
    ) {
        guard case .unresolved = self.mixDetectionState else { return }
        self.unknownDurationParseTask?.cancel()
        self.unknownDurationParseTask = nil

        self.mixDetectionState = .parsing
        self.mixParseStartedWithoutDuration = startedWithoutDuration
        self.mixParseGeneration += 1
        let generation = self.mixParseGeneration
        let videoId = track.videoId
        let parseTask = Task { @MainActor in
            await parser.parseTracklist(videoId: videoId)
        }
        self.mixParseTask = parseTask
        self.scheduleMixParseTimeout(for: track, videoId: videoId, generation: generation)
        self.mixParseMonitorTask = Task { @MainActor [weak self] in
            let tracklist = await parseTask.value
            guard let self else { return }

            // A track change may have cancelled this request and started another. Only the task
            // owning the current generation may clear the in-flight slot or publish its result.
            guard self.mixParseGeneration == generation else { return }
            guard !Task.isCancelled, self.currentTrackVideoId == videoId else { return }
            self.mixParseTimeoutTask?.cancel()
            self.mixParseTimeoutTask = nil
            guard let playerTrack = self.playerService.currentTrack else { return }
            let currentTrackStillMatches = playerTrack.videoId == videoId
                && playerTrack.title == track.title
                && playerTrack.artistsDisplay == track.artistsDisplay
            if !currentTrackStillMatches {
                self.mixParseMonitorTask = nil
                if !self.deferPendingRegularTrackFinalizationIfNeeded() {
                    self.cancelMixTracklistFetch()
                }
                self.pollPlayerState()
                return
            }

            self.mixParseTask = nil
            self.mixParseMonitorTask = nil
            self.trackedSong = playerTrack
            self.updateTrackedVideoDuration(for: playerTrack)
            if let songDuration = playerTrack.duration,
               songDuration > 0,
               songDuration <= Self.mixMinimumVideoDuration
            {
                self.mixParseStartedWithoutDuration = false
                self.resolveAsNotMix()
                self.pollPlayerState()
                return
            }
            let scopedDuration = self.scopedDuration(for: playerTrack)
            let hasSongDuration = playerTrack.duration.map { $0 > 0 } ?? false
            let stillAwaitingDuration = self.mixParseStartedWithoutDuration
                && !hasSongDuration
                && (scopedDuration.map { $0 <= Self.mixMinimumVideoDuration } ?? true)
            self.mixParseStartedWithoutDuration = false
            if let tracklist, tracklist.isMix {
                if stillAwaitingDuration {
                    self.mixDetectionState = .awaitingDuration(tracklist)
                    self.durationConfirmationCompleted = false
                } else {
                    self.resolveAsMix(tracklist)
                }
                self.logger.info("Mix tracklist loaded: \(tracklist.entries.count) sub-tracks for \(playerTrack.title)")
            } else {
                self.resolveAsNotMix()
            }
            self.pollPlayerState()
        }
    }

    private func cancelMixTracklistFetch() {
        self.mixParseGeneration += 1
        self.unknownDurationParseTask?.cancel()
        self.unknownDurationParseTask = nil
        self.durationConfirmationTask?.cancel()
        self.durationConfirmationTask = nil
        self.mixParseMonitorTask?.cancel()
        self.mixParseMonitorTask = nil
        self.mixParseTimeoutTask?.cancel()
        self.mixParseTimeoutTask = nil
        self.mixParseTask?.cancel()
        self.mixParseTask = nil
        self.durationConfirmationCompleted = false
        self.mixParseStartedWithoutDuration = false
    }

    private func updateTrackedVideoDuration(for track: Song) {
        if let duration = track.duration, duration > 0 {
            self.trackedVideoDuration = duration
        } else if self.playerService.playbackStateVideoId == track.videoId,
                  self.playerService.duration > 0
        {
            self.trackedVideoDuration = self.playerService.duration
        }
    }

    private func accumulateWholeTrack(
        progress: TimeInterval,
        isPlaying: Bool,
        recordProvisionalSegment: Bool
    ) {
        guard var tracker = self.trackTracker else { return }
        let segmentStart = tracker.lastProgress
        let now = self.now()
        let credited = tracker.accumulate(progress: progress, isPlaying: isPlaying, now: now)
        self.trackTracker = tracker

        guard recordProvisionalSegment else { return }
        if credited == 0, abs(progress - segmentStart) > 5 {
            self.provisionalMixHistory.recordDiscontinuity(at: progress, startTime: now)
            return
        }
        guard credited > 0 else { return }
        self.provisionalMixHistory.record(
            startProgress: segmentStart,
            endProgress: progress,
            startTime: now.addingTimeInterval(-credited)
        )
    }

    private func finalizeCurrentTrack() {
        self.cancelNowPlayingTasks()

        if case .unresolved = self.mixDetectionState,
           let song = self.trackedSong
        {
            let scopedDuration = self.scopedDuration(for: song)
            if let scopedDuration, scopedDuration <= Self.mixMinimumVideoDuration {
                self.resolveAsNotMix()
            } else if let parser = self.mixTracklistParser,
                      self.provisionalMixHistory.hasPlayback || !self.pendingWholeTrackPlays.isEmpty
            {
                self.startMixParse(
                    for: song,
                    parser: parser,
                    startedWithoutDuration: scopedDuration == nil
                )
            }
        }

        self.resolveAwaitingDurationForFinalization()

        // A qualifying regular track whose parse is still pending finalizes after that parse says
        // it is not a mix. Detaching it keeps the next track's detection independent.
        if !self.deferPendingRegularTrackFinalizationIfNeeded() {
            self.cancelMixTracklistFetch()
        }

        self.finalizeResidualMixHistoryIfNeeded()

        // Finalize mix-mode sub-track if active
        if self.currentMixTracklist != nil, let entry = self.currentMixEntry {
            self.finalizeMixEntry(entry, song: self.trackedSong)
        }

        // Nothing to finalize if no track was being tracked
        guard self.currentTrackVideoId != nil else { return }

        // Final threshold check before discarding accumulated play time (single-track mode only)
        if case .notMix = self.mixDetectionState,
           self.trackTracker?.hasScrobbled == false,
           let song = self.trackedSong
        {
            if let duration = self.trackedVideoDuration {
                self.checkScrobbleThreshold(track: song, duration: duration)
            }
        }

        self.logger.debug("Finalized track (accumulated: \(String(format: "%.1f", self.trackTracker?.accumulatedPlayTime ?? 0))s, scrobbled: \(self.trackTracker?.hasScrobbled ?? false))")

        // Reset tracking state
        self.currentTrackVideoId = nil
        self.currentTrackTitle = nil
        self.currentTrackArtist = nil
        self.requiredPlaybackStateSequence = nil
        self.trackedSong = nil
        self.trackTracker = nil
        self.trackedVideoDuration = nil
        self.pendingWholeTrackPlays.removeAll()

        // Reset mix-mode state
        self.mixDetectionState = .unresolved
        self.currentMixEntry = nil
        self.mixEntryTracker = nil
        self.mixEntryScrobbledIds.removeAll()
        self.provisionalMixHistory.removeAll()
        self.provisionalCurrentMixCredit = nil
    }

    // MARK: - Scrobble Threshold

    /// Whole-track thresholds treat unknown duration as ineligible.
    var trackThresholds: PlaybackScrobbleTracker.Thresholds {
        .init(
            percent: self.settingsManager.scrobblePercentThreshold,
            minSeconds: self.settingsManager.scrobbleMinSeconds,
            allowsUnknownDuration: false
        )
    }

    /// Mix sub-tracks with unknown chapter bounds can still qualify via `minSeconds`.
    var mixEntryThresholds: PlaybackScrobbleTracker.Thresholds {
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

    /// Handles per-sub-track scrobbling when a mix tracklist is available.
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
                if let endTime = tracklist.effectiveEndTime(
                    for: prevEntry,
                    videoDuration: self.videoDuration(for: track)
                ),
                    let tracker = self.mixEntryTracker
                {
                    let progressDelta = progress - tracker.lastProgress
                    if progress >= endTime, progressDelta > 0, progressDelta < 2 {
                        self.mixEntryTracker?.accumulate(
                            progress: endTime,
                            isPlaying: isPlaying,
                            now: self.now()
                        )
                    }
                }
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

        // A backward jump after scrobbling is a replay and gets a fresh timestamp. Other seeks
        // only reset accumulated play time; already-sent latches remain set to prevent duplicates.
        if let tracker = self.mixEntryTracker, abs(progress - tracker.lastProgress) > 5.0 {
            let restartedNearEntryStart = progress <= entry.startTime + Self.mixReplayStartTolerance
            if tracker.hasScrobbled,
               progress < tracker.lastProgress - 5.0,
               restartedNearEntryStart
            {
                self.mixEntryScrobbledIds.remove(entry.id)
                self.mixEntryTracker = PlaybackScrobbleTracker(startTime: self.now(), initialProgress: progress)
                self.logger.debug("Mix replay detected at \(String(format: "%.1f", progress))s for sub-track '\(entry.title)'")
            } else {
                self.mixEntryTracker?.resetForSeek()
                self.logger.debug("Mix seek detected at \(String(format: "%.1f", progress))s, resetting sub-track accumulation for '\(entry.title)'")
            }
        }

        // Accumulate play time (the tracker ignores seeks and paused spans internally)
        self.mixEntryTracker?.accumulate(progress: progress, isPlaying: isPlaying, now: self.now())

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
        let pendingCredit = self.provisionalCurrentMixCredit
        self.provisionalCurrentMixCredit = nil
        let provisionalCredit = pendingCredit.flatMap { credit in
            credit.entryId == entry.id ? credit.credit : nil
        }
        let isConfirmedReplay = self.mixEntryScrobbledIds.contains(entry.id)
            && progress <= entry.startTime + Self.mixReplayStartTolerance
        if isConfirmedReplay {
            self.mixEntryScrobbledIds.remove(entry.id)
        }
        var tracker = PlaybackScrobbleTracker(
            startTime: provisionalCredit?.startTime ?? self.now(),
            initialProgress: progress
        )
        if let provisionalCredit {
            tracker.creditVerifiedPlayTime(provisionalCredit.accumulatedPlayTime)
            if provisionalCredit.hasScrobbled {
                tracker.markScrobbled()
                self.mixEntryScrobbledIds.insert(entry.id)
            }
        }
        if self.mixEntryScrobbledIds.contains(entry.id) {
            tracker.markScrobbled()
        }
        self.mixEntryTracker = tracker
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
        let duration = self.mixEntryDuration(entry, song: song)
        guard var tracker = self.mixEntryTracker,
              tracker.meetsThreshold(duration: duration, thresholds: self.mixEntryThresholds)
        else { return }

        tracker.markScrobbled()
        self.mixEntryTracker = tracker
        self.mixEntryScrobbledIds.insert(entry.id)

        let scrobbleTrack = ScrobbleTrack(
            title: entry.title,
            artist: entry.artist ?? song?.artistsDisplay ?? "Unknown Artist",
            album: nil,
            duration: duration,
            timestamp: tracker.startTime,
            videoId: song?.videoId
        )
        self.queue.enqueue(scrobbleTrack)
        self.scheduleQueueFlushIfNeeded()
        self.logger.info("Mix scrobble: \(entry.artist ?? "?") - \(entry.title) (accumulated: \(String(format: "%.1f", tracker.accumulatedPlayTime))s)")
    }

    // MARK: - Queue Flush

    func scheduleQueueFlushIfNeeded(after delay: Duration = .seconds(30)) {
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
