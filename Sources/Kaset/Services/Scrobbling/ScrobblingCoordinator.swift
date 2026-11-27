import Foundation
import Observation

@MainActor
@Observable
final class ScrobblingCoordinator {
    static let mixMinimumVideoDuration: TimeInterval = 600
    static let mixReplayStartTolerance: TimeInterval = 5

    let playerService: PlayerService
    private let settingsManager: any ScrobblingSettingsProviding
    let services: [any ScrobbleServiceProtocol]
    let logger = DiagnosticsLogger.scrobbling

    let queue: ScrobbleQueue

    let mixTracklistParser: MixTracklistParser?
    let unknownDurationParseDelay: Duration
    let mixParseTimeout: Duration
    private let now: () -> Date

    var currentTrackVideoId: String?

    private var currentTrackTitle: String?

    private var currentTrackArtist: String?
    var requiredPlaybackStateSequence: Int?

    var trackedSong: Song?

    var trackTracker: PlaybackScrobbleTracker?
    var pendingWholeTrackPlays: [PendingWholeTrackPlay] = []

    var trackedVideoDuration: TimeInterval?

    var mixDetectionState: MixDetectionState = .unresolved

    private var currentMixEntry: MixTrackEntry?

    var mixEntryTracker: PlaybackScrobbleTracker?
    var mixEntryScrobbledIds: Set<UUID> = []

    var mixParseTask: Task<MixTracklist?, Never>?
    var mixParseMonitorTask: Task<Void, Never>?
    var mixParseTimeoutTask: Task<Void, Never>?
    var unknownDurationParseTask: Task<Void, Never>?
    var durationConfirmationTask: Task<Void, Never>?
    var durationConfirmationCompleted = false
    var mixParseStartedWithoutDuration = false

    var mixParseGeneration = 0

    var pendingMixFinalizations: [UUID: PendingMixFinalization] = [:]

    var provisionalMixHistory = ProvisionalMixPlaybackHistory()
    var provisionalCurrentMixCredit: (entryId: UUID, credit: ProvisionalMixPlaybackHistory.Credit)?

    var currentMixTracklist: MixTracklist? {
        guard case let .mix(tracklist) = self.mixDetectionState else { return nil }
        return tracklist
    }

    // swiftformat:disable modifierOrder
    private var flushTask: Task<Void, Never>?

    private var flushTaskGeneration = 0

    var nowPlayingTasks: [Task<Void, Never>] = []
    // swiftformat:enable modifierOrder

    private(set) var isMonitoring = false

    private var monitoringGeneration = 0

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

    deinit {}

    private var hasAnyEnabledConnectedService: Bool {
        self.services.contains { service in
            self.settingsManager.isServiceEnabled(service.serviceName) && service.authState.isConnected
        }
    }

    var enabledConnectedServices: [any ScrobbleServiceProtocol] {
        self.services.filter { service in
            self.settingsManager.isServiceEnabled(service.serviceName) && service.authState.isConnected
        }
    }

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

    func restoreAuthState() {
        for service in self.services {
            service.restoreSession()
        }
    }

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

    func pollPlayerState() {
        guard self.hasAnyEnabledConnectedService else { return }

        let currentTrack = self.playerService.currentTrack
        let isPlaying = self.playerService.isPlaying
        let progress = self.playerService.progress

        if let track = currentTrack {
            let videoIdChanged = track.videoId != self.currentTrackVideoId
            let metadataChanged = self.currentTrackVideoId != nil
                && (track.title != self.currentTrackTitle || track.artistsDisplay != self.currentTrackArtist)

            if videoIdChanged || metadataChanged {
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

            self.resolveMixDetection(for: track)
            switch self.mixDetectionState {
            case .unresolved, .parsing, .awaitingDuration:
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

            self.accumulateWholeTrack(
                progress: progress,
                isPlaying: isPlaying,
                recordProvisionalSegment: false
            )

            if self.trackTracker?.hasSentNowPlaying == false, isPlaying {
                self.sendNowPlaying(track)
            }

            if self.trackTracker?.hasScrobbled == false, let duration = self.trackedVideoDuration {
                self.checkScrobbleThreshold(track: track, duration: duration)
            }
        } else if self.currentTrackVideoId != nil {
            self.finalizeCurrentTrack()
        }
    }

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
    }

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

        if !self.deferPendingRegularTrackFinalizationIfNeeded() {
            self.cancelMixTracklistFetch()
        }

        self.finalizeResidualMixHistoryIfNeeded()

        if self.currentMixTracklist != nil, let entry = self.currentMixEntry {
            self.finalizeMixEntry(entry, song: self.trackedSong)
        }

        guard self.currentTrackVideoId != nil else { return }

        if case .notMix = self.mixDetectionState,
           self.trackTracker?.hasScrobbled == false,
           let song = self.trackedSong
        {
            if let duration = self.trackedVideoDuration {
                self.checkScrobbleThreshold(track: song, duration: duration)
            }
        }

        self.logger.debug("Finalized track (accumulated: \(String(format: "%.1f", self.trackTracker?.accumulatedPlayTime ?? 0))s, scrobbled: \(self.trackTracker?.hasScrobbled ?? false))")

        self.currentTrackVideoId = nil
        self.currentTrackTitle = nil
        self.currentTrackArtist = nil
        self.requiredPlaybackStateSequence = nil
        self.trackedSong = nil
        self.trackTracker = nil
        self.trackedVideoDuration = nil
        self.pendingWholeTrackPlays.removeAll()

        self.mixDetectionState = .unresolved
        self.currentMixEntry = nil
        self.mixEntryTracker = nil
        self.mixEntryScrobbledIds.removeAll()
        self.provisionalMixHistory.removeAll()
        self.provisionalCurrentMixCredit = nil
    }

    var trackThresholds: PlaybackScrobbleTracker.Thresholds {
        .init(
            percent: self.settingsManager.scrobblePercentThreshold,
            minSeconds: self.settingsManager.scrobbleMinSeconds,
            allowsUnknownDuration: false
        )
    }

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

    private func handleMixPlayback(
        track: Song,
        tracklist: MixTracklist,
        progress: TimeInterval,
        isPlaying: Bool
    ) {
        let entry = tracklist.entry(at: progress)

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
                self.currentMixEntry = nil
            }
        }

        guard let entry, self.currentMixEntry?.id == entry.id else { return }

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

        self.mixEntryTracker?.accumulate(progress: progress, isPlaying: isPlaying, now: self.now())

        if self.mixEntryTracker?.hasSentNowPlaying == false, isPlaying {
            self.sendMixNowPlaying(entry, song: track)
        }

        if self.mixEntryTracker?.hasScrobbled == false {
            self.checkMixEntryScrobbleThreshold(entry: entry, song: track)
        }
    }

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

    private func finalizeMixEntry(_ entry: MixTrackEntry, song: Song?) {
        if self.mixEntryTracker?.hasScrobbled == false {
            self.checkMixEntryScrobbleThreshold(entry: entry, song: song)
        }

        self.logger.debug("Mix sub-track finalized: \(entry.artist ?? "?") - \(entry.title) (accumulated: \(String(format: "%.1f", self.mixEntryTracker?.accumulatedPlayTime ?? 0))s, scrobbled: \(self.mixEntryTracker?.hasScrobbled ?? false))")

        self.currentMixEntry = nil
        self.mixEntryTracker = nil
    }

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

    var isQueueFlushScheduled: Bool {
        guard let flushTask else { return false }
        return !flushTask.isCancelled
    }

    func flushQueue() async {
        guard self.hasAnyEnabledConnectedService else { return }
        guard !self.queue.isEmpty else { return }

        self.queue.pruneExpired()

        let batch = self.queue.dequeue(limit: 50)
        guard !batch.isEmpty else { return }

        self.logger.debug("Flushing \(batch.count) scrobbles from queue")

        var acceptedIds = Set<UUID>()

        for service in self.enabledConnectedServices {
            do {
                let results = try await service.scrobble(batch)

                let accepted = results.filter(\.accepted)
                if !accepted.isEmpty {
                    acceptedIds.formUnion(accepted.map(\.track.id))
                    self.logger.info("Flushed \(accepted.count)/\(batch.count) scrobbles to \(service.serviceName)")
                }

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

        if !acceptedIds.isEmpty {
            self.queue.markCompleted(acceptedIds)
        }
    }
}
