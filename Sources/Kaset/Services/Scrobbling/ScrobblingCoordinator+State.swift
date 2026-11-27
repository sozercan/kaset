import Foundation

extension ScrobblingCoordinator {
    enum MixDetectionState {
        case unresolved
        case parsing
        case awaitingDuration(MixTracklist)
        case notMix
        case mix(MixTracklist)
    }

    enum MixDurationDecisionPhase {
        case activeBeforeGrace
        case activeAfterGrace
        case finalization
    }

    enum MixDurationDecision {
        case unresolved
        case provisionalNotMix
        case notMix
        case mix
    }

    enum DeferredMixParseOutcome {
        case parsed(MixTracklist?)
        case timedOut
    }

    struct PendingMixFinalization {
        let parseTask: Task<MixTracklist?, Never>
        let finalizationTask: Task<Void, Never>
        let fallbackScrobbles: [ScrobbleTrack]
    }

    func scopedDuration(for track: Song) -> TimeInterval? {
        if let duration = track.duration, duration > 0 {
            return duration
        }
        return self.scopedPlayerDuration(for: track)
    }

    func scopedPlayerDuration(for track: Song) -> TimeInterval? {
        guard self.playerService.playbackStateVideoId == track.videoId,
              self.playerService.duration > 0
        else { return nil }
        return self.playerService.duration
    }

    func videoDuration(for song: Song?) -> TimeInterval? {
        if song?.videoId == self.currentTrackVideoId, let trackedVideoDuration {
            return trackedVideoDuration
        }
        if let duration = song?.duration, duration > 0 {
            return duration
        }
        return nil
    }

    func mixEntryDuration(_ entry: MixTrackEntry, song: Song?) -> TimeInterval? {
        guard let tracklist = self.currentMixTracklist else { return entry.duration }
        return tracklist.effectiveDuration(for: entry, videoDuration: self.videoDuration(for: song))
    }

    func acceptPlaybackState(for track: Song) -> Bool {
        guard self.playerService.playbackStateVideoId == track.videoId else { return false }
        if let requiredPlaybackStateSequence = self.requiredPlaybackStateSequence {
            guard self.playerService.playbackStateObservationSequence >= requiredPlaybackStateSequence else {
                return false
            }
            self.requiredPlaybackStateSequence = nil
        }
        return true
    }

    static func tracklistProvesMixDuration(_ tracklist: MixTracklist) -> Bool {
        tracklist.knownDurationLowerBound.map { $0 > Self.mixMinimumVideoDuration } == true
    }

    static func mixDurationDecision(
        for tracklist: MixTracklist,
        songDuration: TimeInterval?,
        playerDuration: TimeInterval?,
        phase: MixDurationDecisionPhase
    ) -> MixDurationDecision {
        if let songDuration, songDuration > 0 {
            return songDuration > mixMinimumVideoDuration ? .mix : .notMix
        }
        if let playerDuration, playerDuration > Self.mixMinimumVideoDuration {
            return .mix
        }
        guard phase != .activeBeforeGrace else { return .unresolved }
        if Self.tracklistProvesMixDuration(tracklist) {
            return .mix
        }
        if let playerDuration, playerDuration > 0 {
            return phase == .finalization ? .notMix : .provisionalNotMix
        }
        return phase == .finalization ? .mix : .unresolved
    }

    @discardableResult
    func applyMixDurationDecision(
        _ decision: MixDurationDecision,
        tracklist: MixTracklist
    ) -> Bool {
        switch decision {
        case .unresolved, .provisionalNotMix:
            return false
        case .notMix:
            self.resolveAsNotMix()
        case .mix:
            self.resolveAsMix(tracklist)
        }
        return true
    }

    func resolveAsMix(_ tracklist: MixTracklist) {
        self.mixDetectionState = .mix(tracklist)
        self.unknownDurationParseTask?.cancel()
        self.unknownDurationParseTask = nil
        self.durationConfirmationTask?.cancel()
        self.durationConfirmationTask = nil
        self.durationConfirmationCompleted = false
        self.pendingWholeTrackPlays.removeAll()
        self.consumeProvisionalPlayback(for: tracklist, song: self.trackedSong)
    }

    func resolveAsNotMix() {
        self.mixDetectionState = .notMix
        self.provisionalMixHistory.removeAll()
        self.unknownDurationParseTask?.cancel()
        self.unknownDurationParseTask = nil
        self.durationConfirmationTask?.cancel()
        self.durationConfirmationTask = nil
        self.durationConfirmationCompleted = false
        self.commitPendingWholeTrackScrobbles()
    }

    func resolveAwaitingDurationForFinalization() {
        guard case let .awaitingDuration(tracklist) = self.mixDetectionState else { return }
        let decision = Self.mixDurationDecision(
            for: tracklist,
            songDuration: self.trackedSong?.duration,
            playerDuration: self.trackedVideoDuration,
            phase: .finalization
        )
        self.applyMixDurationDecision(decision, tracklist: tracklist)
    }

    struct PendingWholeTrackPlay {
        let tracker: PlaybackScrobbleTracker
        let song: Song
    }
}
