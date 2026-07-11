import Foundation

extension ScrobblingCoordinator {
    func revalidatePendingWholeTrackLatchIfNeeded() {
        switch self.mixDetectionState {
        case .unresolved, .parsing, .awaitingDuration:
            break
        case .notMix, .mix:
            return
        }
        guard var tracker = self.trackTracker,
              tracker.hasScrobbled,
              !tracker.meetsThreshold(
                  duration: self.trackedVideoDuration,
                  thresholds: self.trackThresholds
              )
        else { return }

        tracker.clearScrobbledLatch()
        self.trackTracker = tracker
        self.pendingWholeTrackPlays.removeAll {
            $0.tracker.startTime == tracker.startTime
        }
    }

    func refreshPendingWholeTrackPlay(with tracker: PlaybackScrobbleTracker) {
        guard let lastIndex = self.pendingWholeTrackPlays.indices.last,
              self.pendingWholeTrackPlays[lastIndex].tracker.startTime == tracker.startTime
        else { return }
        self.pendingWholeTrackPlays[lastIndex] = PendingWholeTrackPlay(
            tracker: tracker,
            song: self.pendingWholeTrackPlays[lastIndex].song
        )
    }

    func capturePendingWholeTrackScrobbleIfNeeded(_ track: Song) {
        guard var tracker = self.trackTracker,
              !tracker.hasScrobbled,
              let duration = self.trackedVideoDuration,
              tracker.meetsThreshold(duration: duration, thresholds: self.trackThresholds)
        else { return }

        tracker.markScrobbled()
        self.trackTracker = tracker
        self.pendingWholeTrackPlays.append(PendingWholeTrackPlay(tracker: tracker, song: track))
    }

    func commitPendingWholeTrackScrobbles() {
        guard !self.pendingWholeTrackPlays.isEmpty else { return }
        let duration = self.trackedVideoDuration
        var plays = self.pendingWholeTrackPlays
        if let tracker = self.trackTracker,
           let lastIndex = plays.indices.last,
           plays[lastIndex].tracker.startTime == tracker.startTime
        {
            plays[lastIndex] = PendingWholeTrackPlay(tracker: tracker, song: plays[lastIndex].song)
        }
        for scrobble in self.wholeTrackScrobbles(
            from: plays,
            duration: duration,
            thresholds: self.trackThresholds
        ) {
            self.queue.enqueue(scrobble)
        }
        if var tracker = self.trackTracker,
           tracker.hasScrobbled,
           !tracker.meetsThreshold(duration: duration, thresholds: self.trackThresholds)
        {
            tracker.clearScrobbledLatch()
            self.trackTracker = tracker
        }
        self.pendingWholeTrackPlays.removeAll()
        self.scheduleQueueFlushIfNeeded()
    }

    func wholeTrackScrobbles(
        from plays: [PendingWholeTrackPlay],
        duration: TimeInterval?,
        thresholds: PlaybackScrobbleTracker.Thresholds
    ) -> [ScrobbleTrack] {
        plays.compactMap { play in
            guard play.tracker.meetsThreshold(duration: duration, thresholds: thresholds) else { return nil }
            return ScrobbleTrack(
                title: play.song.title,
                artist: play.song.artistsDisplay,
                album: play.song.album?.title,
                duration: duration,
                timestamp: play.tracker.startTime,
                videoId: play.song.videoId
            )
        }
    }
}
