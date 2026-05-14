import Foundation

// MARK: - Web Queue Sync

@MainActor
extension PlayerService {
    private func applyDeferredRestoredMetadata(
        title: String,
        artist: String,
        thumbnailUrl: String,
        videoId observedVideoId: String?
    ) {
        guard let observedVideoId = self.normalizedObservedVideoId(observedVideoId) else { return }

        let thumbnailURL = URL(string: thumbnailUrl)
        let artistObj = Artist(id: "unknown", name: artist)
        let matchedQueueSong = self.queue.first(where: { $0.videoId == observedVideoId })
        let seedSong: Song

        let previousVideoId = self.currentTrack?.videoId
        self.pendingPlayVideoId = observedVideoId
        self.isKasetInitiatedPlayback = false
        self.isAwaitingWebRestoredTrack = false

        // Sync the web view's current video ID so Kaset knows the player is already on this track
        SingletonPlayerWebView.shared.currentVideoId = observedVideoId
        if observedVideoId == previousVideoId, !self.queue.isEmpty {
            return
        }
        self.mixContinuationToken = nil

        if let matchedQueueSong,
           self.shouldKeepQueueMetadata(title: title, artist: artist, song: matchedQueueSong)
        {
            seedSong = matchedQueueSong
        } else {
            seedSong = Song(
                id: observedVideoId,
                title: title,
                artists: [artistObj],
                album: nil,
                duration: self.duration > 0 ? self.duration : nil,
                thumbnailURL: thumbnailURL,
                videoId: observedVideoId
            )
        }

        self.clearForwardSkipNavigationStack()
        self.setQueue([seedSong])
        self.currentIndex = 0
        self.currentTrack = seedSong
        self.currentTrackHasVideo = seedSong.musicVideoType?.hasVideoContent
            ?? seedSong.hasVideo
            ?? false
        self.saveQueueForPersistence()

        Task {
            await self.fetchAndApplyRadioQueue(for: observedVideoId)
        }

        if previousVideoId != observedVideoId {
            self.resetTrackStatus()
            if let cachedStatus = SongLikeStatusManager.shared.status(for: observedVideoId) {
                self.currentTrackLikeStatus = cachedStatus
            }
            Task {
                await self.fetchSongMetadata(videoId: observedVideoId)
            }
        }
    }

    /// Distance from `duration` at which a manual seek is treated as the end of the track.
    /// `video.currentTime = duration` does not reliably fire `ended` in WebKit, and a subsequent
    /// play call would restart the same song from 0 instead of advancing.
    static let seekToEndThreshold: TimeInterval = 0.5

    /// Routes a manual seek that landed at the end of the track through the track-ended path so
    /// repeat / queue / autoplay-suppression rules apply consistently with a natural end.
    func handleManualSeekToEnd() async {
        self.logger.info("Manual seek reached end of track; routing through track-ended path")
        self.clearRestoredPlaybackSessionState()
        self.progress = self.duration

        if self.shouldSynchronizeWebViewForTerminalManualSeekToEnd {
            SingletonPlayerWebView.shared.seekAndPause(to: self.duration)
        }

        await self.handleTrackEnded(observedVideoId: self.currentTrack?.videoId)
    }

    private var shouldSynchronizeWebViewForTerminalManualSeekToEnd: Bool {
        if self.queue.isEmpty {
            return !(self.repeatMode == .one && (self.currentTrack != nil || self.pendingPlayVideoId != nil))
        }

        return !self.canAdvanceNativeQueueAfterTrackEnd
    }

    private func normalizedObservedVideoId(_ videoId: String?) -> String? {
        guard let videoId, !videoId.isEmpty else { return nil }
        return videoId
    }

    private func resolvedObservedVideoId(_ videoId: String?) -> String {
        self.normalizedObservedVideoId(videoId) ?? self.currentTrack?.videoId ?? self.pendingPlayVideoId ?? "unknown"
    }

    private func observedTrackMatchesSong(
        observedVideoId: String?,
        title: String,
        artist: String,
        song: Song
    ) -> Bool {
        if let observedVideoId = self.normalizedObservedVideoId(observedVideoId) {
            return song.videoId == observedVideoId
        }
        return song.title == title && song.artistsDisplay == artist
    }

    private func metadataMatchesSong(title: String, artist: String, song: Song) -> Bool {
        song.title == title && song.artistsDisplay == artist
    }

    private func shouldKeepQueueMetadata(title: String, artist: String, song: Song) -> Bool {
        title.isEmpty || artist.isEmpty || !self.metadataMatchesSong(title: title, artist: artist, song: song)
    }

    /// Synchronizes Kaset's expected next track with YouTube Music's native "Up Next" queue.
    /// By injecting the next track ahead of time, we achieve true gapless playback when the current track ends.
    ///
    /// **Important:** Only runs when the player is in a stable state (`.playing` or `.paused`).
    /// During `.loading` (SPA navigation), the player bar DOM is in flux and clicking the 3-dot
    /// menu would interfere with `resolveCommand`. The injection is safely deferred to
    /// `confirmPlaybackStarted()` which fires once the song is actually playing.
    func syncWebQueue() {
        // Never manipulate the DOM during navigation — the MutationObserver in
        // injectNextSong conflicts with resolveCommand's DOM mutations.
        guard self.state == .playing || self.state == .paused else { return }

        guard let nextIndex = self.expectedQueueIndexAfterCurrentTrack(),
              let nextSong = self.queue[safe: nextIndex] else { return }

        if self.injectedWebQueueVideoId != nextSong.videoId {
            self.injectedWebQueueVideoId = nextSong.videoId
            SingletonPlayerWebView.shared.injectNextSong(videoId: nextSong.videoId)
            self.logger.info("Synced web queue: injected \(nextSong.videoId) to play next natively")
        }
    }

    private var canAdvanceNativeQueueAfterTrackEnd: Bool {
        self.shuffleEnabled
            || self.repeatMode == .one
            || self.currentIndex < self.queue.count - 1
            || self.repeatMode == .all
            || self.mixContinuationToken != nil
    }

    private func expectedQueueIndexAfterCurrentTrack() -> Int? {
        guard !self.queue.isEmpty else { return nil }
        if self.repeatMode == .one {
            return self.currentIndex
        }
        guard !self.shuffleEnabled else { return nil }
        if self.currentIndex < self.queue.count - 1 {
            return self.currentIndex + 1
        }
        if self.repeatMode == .all {
            return 0
        }
        return nil
    }

    private func isRepeatAllWraparoundTrackEnd(
        observedVideoId: String,
        expectedCurrentVideoId: String
    ) -> Bool {
        guard self.repeatMode == .all,
              !self.shuffleEnabled,
              self.expectedQueueIndexAfterCurrentTrack() == 0,
              let currentQueueSong = self.queue[safe: self.currentIndex],
              let firstQueueSong = self.queue.first
        else {
            return false
        }

        // At the repeat-all boundary, YouTube can report the first queue song as the
        // observed id before the natural `ended` callback reaches Kaset.
        return currentQueueSong.videoId == expectedCurrentVideoId
            && firstQueueSong.videoId == observedVideoId
    }

    private func keepQueueSongVisible(_ song: Song, thumbnailUrl: String) {
        let intendedThumbnailURL = URL(string: thumbnailUrl) ?? song.thumbnailURL
        self.currentTrack = Song(
            id: song.id,
            title: song.title,
            artists: song.artists,
            album: song.album,
            duration: song.duration,
            thumbnailURL: intendedThumbnailURL,
            videoId: song.videoId,
            hasVideo: song.hasVideo,
            musicVideoType: song.musicVideoType,
            likeStatus: song.likeStatus,
            isInLibrary: song.isInLibrary,
            feedbackTokens: song.feedbackTokens
        )
    }

    private func suppressUnexpectedAutoplayAfterQueueEndIfNeeded(
        trackChanged: Bool,
        observedVideoId: String?,
        title: String,
        artist: String,
        thumbnailUrl: String
    ) -> Bool {
        guard trackChanged,
              self.shouldSuppressAutoplayAfterQueueEnd,
              let currentQueueSong = self.queue[safe: self.currentIndex],
              !self.observedTrackMatchesSong(
                  observedVideoId: observedVideoId,
                  title: title,
                  artist: artist,
                  song: currentQueueSong
              )
        else {
            return false
        }

        self.markPlaybackEnded()
        self.logger.info("Suppressing unexpected autoplay after native queue ended")
        self.keepQueueSongVisible(currentQueueSong, thumbnailUrl: thumbnailUrl)
        Task {
            await self.pause()
        }
        return true
    }

    private func handleKasetInitiatedPlaybackMetadata(
        observedVideoId: String?,
        title: String,
        artist: String,
        thumbnailUrl: String,
        trackChanged: Bool
    ) -> Bool {
        guard self.isKasetInitiatedPlayback, !self.queue.isEmpty else {
            return false
        }

        guard let intendedSong = self.queue[safe: self.currentIndex] else {
            self.isKasetInitiatedPlayback = false
            return false
        }

        let matchesObservedVideo = self.normalizedObservedVideoId(observedVideoId) == intendedSong.videoId
        if matchesObservedVideo, self.shouldKeepQueueMetadata(title: title, artist: artist, song: intendedSong) {
            self.isKasetInitiatedPlayback = false
            self.logger.debug(
                "Confirmed intended videoId \(intendedSong.videoId) with incomplete metadata '\(title)'; keeping queue metadata"
            )
            self.keepQueueSongVisible(intendedSong, thumbnailUrl: thumbnailUrl)
            return true
        }

        if self.observedTrackMatchesSong(
            observedVideoId: observedVideoId,
            title: title,
            artist: artist,
            song: intendedSong
        ) {
            self.isKasetInitiatedPlayback = false
            self.logger.debug("Confirmed Kaset-initiated playback for '\(intendedSong.title)'")
            return false
        }

        guard trackChanged else {
            return false
        }

        let resolvedVideoId = self.resolvedObservedVideoId(observedVideoId)
        self.logger.info(
            "YouTube loaded different track '\(title)' (\(resolvedVideoId)), re-playing intended track '\(intendedSong.title)'"
        )
        self.isKasetInitiatedPlayback = false
        Task {
            await self.play(song: intendedSong, webLoadStrategy: .forceFullPageWhenSameVideoId)
        }
        return true
    }

    private func handleNearEndTrackChangeIfNeeded(
        observedVideoId: String?,
        title: String,
        artist: String,
        thumbnailUrl: String,
        trackChanged: Bool
    ) -> Bool {
        guard trackChanged, !self.queue.isEmpty, self.songNearingEnd else {
            return false
        }

        self.songNearingEnd = false
        if let expectedNextIndex = self.expectedQueueIndexAfterCurrentTrack(),
           let expectedNextTrack = self.queue[safe: expectedNextIndex]
        {
            if !self.observedTrackMatchesSong(
                observedVideoId: observedVideoId,
                title: title,
                artist: artist,
                song: expectedNextTrack
            ) {
                // Repeat one: "expected next" is still the current row — do not call `next()` (that advances the queue).
                if self.repeatMode == .one {
                    self.logger.info(
                        "YouTube autoplay near end during repeat one; re-asserting current queue track (not advancing)"
                    )
                    Task {
                        await self.replayCurrentQueueSongForRepeatOneAfterTrackEnd()
                    }
                    return true
                }
                self.logger.info("YouTube autoplay detected, overriding with queue track")
                Task {
                    await self.next()
                }
                return true
            }

            self.currentIndex = expectedNextIndex
            self.logger.info("Track advanced to queue index \(expectedNextIndex)")
            self.saveQueueForPersistence()

            if self.shouldKeepQueueMetadata(title: title, artist: artist, song: expectedNextTrack) {
                self.logger.debug(
                    "Observed queue track \(expectedNextTrack.videoId) with incomplete metadata; keeping queue metadata"
                )
                self.keepQueueSongVisible(expectedNextTrack, thumbnailUrl: thumbnailUrl)
                return true
            }
            return false
        }

        if self.canAdvanceNativeQueueAfterTrackEnd {
            if self.repeatMode == .one {
                self.logger.info("Near-end track change with repeat one; re-asserting current queue track")
                Task {
                    await self.replayCurrentQueueSongForRepeatOneAfterTrackEnd()
                }
                return true
            }
            self.logger.info("Near-end track change detected, advancing native queue to enforce playback order")
            Task {
                await self.next()
            }
            return true
        }

        self.markPlaybackEnded()
        self.logger.info("Unexpected autoplay detected at end of native queue; pausing playback")
        Task {
            await self.pause()
        }
        return true
    }

    /// Last-line repeat-one enforcement: WebView metadata is lossy/out-of-order; earlier handlers can miss a frame.
    /// This does **not** guarantee recovery if the bridge stops firing — only consolidates what we can observe here.
    private func finalRepeatOneSafetyNetIfNeeded(
        observedVideoId: String?,
        title: String,
        artist: String,
        thumbnailUrl: String,
        trackChanged: Bool
    ) -> Bool {
        guard self.repeatMode == .one,
              self.hasUserInteractedThisSession,
              let queued = self.queue[safe: self.currentIndex]
        else {
            return false
        }

        let observedNorm = self.normalizedObservedVideoId(observedVideoId)
        let videoMismatch = observedNorm.map { $0 != queued.videoId } ?? false
        let titleDriftWithoutVideoId =
            observedNorm == nil
                && !title.isEmpty
                && trackChanged
                && !self.metadataMatchesSong(title: title, artist: artist, song: queued)

        guard videoMismatch || titleDriftWithoutVideoId else {
            return false
        }

        self.keepQueueSongVisible(queued, thumbnailUrl: thumbnailUrl)

        let now = ContinuousClock.now
        if let last = self.lastRepeatOneRecoveryInstant,
           now - last < .milliseconds(450)
        {
            self.logger.debug("Repeat one: safety net throttled (bursty metadata)")
            return true
        }
        self.lastRepeatOneRecoveryInstant = now

        self.logger.info("Repeat one: safety net re-asserting queue track (observed=\(observedNorm ?? "nil"))")
        Task {
            await self.play(song: queued, webLoadStrategy: .forceFullPageWhenSameVideoId)
        }
        return true
    }

    private func handleUnexpectedQueueDriftIfNeeded(
        observedVideoId: String?,
        title: String,
        artist: String,
        thumbnailUrl: String,
        trackChanged: Bool
    ) -> Bool {
        guard !self.queue.isEmpty,
              let observedVideoId = self.normalizedObservedVideoId(observedVideoId),
              let currentQueueSong = self.queue[safe: self.currentIndex],
              currentQueueSong.videoId != observedVideoId
        else {
            return false
        }

        // Repeat one: autoplay can swap the video before title/artist update, so `trackChanged` may still be false.
        // Without this branch we fall through and assign `currentTrack` from YouTube, breaking UI sync.
        guard trackChanged || self.repeatMode == .one else {
            return false
        }

        // Repeat one: never realign `currentIndex` to another queue item when YouTube briefly loads
        // a different in-queue video (autoplay); that would break repeat and jump the queue pointer.
        if self.repeatMode == .one {
            self.logger.info(
                "Repeat one: observed \(observedVideoId) diverged from queue; re-playing without advancing queue index"
            )
            Task {
                await self.play(song: currentQueueSong, webLoadStrategy: .forceFullPageWhenSameVideoId)
            }
            return true
        }

        if let matchingIndex = self.queue.firstIndex(where: { $0.videoId == observedVideoId }),
           let matchingSong = self.queue[safe: matchingIndex]
        {
            let queueIndexChanged = matchingIndex != self.currentIndex
            if queueIndexChanged {
                self.currentIndex = matchingIndex
                self.logger.info("Observed playback moved to queue index \(matchingIndex), realigning native queue")
                self.saveQueueForPersistence()
            }

            if queueIndexChanged || self.shouldKeepQueueMetadata(title: title, artist: artist, song: matchingSong) {
                if self.currentTrack?.videoId != matchingSong.videoId {
                    self.resetTrackStatus()
                    // Immediately restore like status from SongLikeStatusManager cache
                    if let cachedStatus = SongLikeStatusManager.shared.status(for: matchingSong.videoId) {
                        self.currentTrackLikeStatus = cachedStatus
                    }
                }
                self.keepQueueSongVisible(matchingSong, thumbnailUrl: thumbnailUrl)
                return true
            }
            return false
        }

        self.logger.info(
            "Observed track \(observedVideoId) diverged from native queue track \(currentQueueSong.videoId); re-playing intended queue track"
        )
        Task {
            await self.play(song: currentQueueSong, webLoadStrategy: .forceFullPageWhenSameVideoId)
        }
        return true
    }

    /// Replays the current queue song after a natural `ended` event. User-initiated **Next** uses ``PlayerService/next()`` instead.
    private func replayCurrentQueueSongForRepeatOneAfterTrackEnd() async {
        guard let currentSong = self.queue[safe: self.currentIndex] else { return }
        self.songNearingEnd = false
        let kasetAlignedWithQueue = self.pendingPlayVideoId == currentSong.videoId
            && SingletonPlayerWebView.shared.currentVideoId == currentSong.videoId
        if self.hasUserInteractedThisSession, kasetAlignedWithQueue {
            SingletonPlayerWebView.shared.restartInPlaceFromBeginning()
            if self.state == .ended || self.state == .loading {
                self.state = .playing
            }
        } else {
            await self.play(song: currentSong, webLoadStrategy: .preferInPlaceWhenSameVideoId)
        }
    }

    /// Replays the currently playing song for repeat-one when no native queue is active.
    private func replayCurrentSongForRepeatOneWithoutQueueAfterTrackEnd() async {
        self.songNearingEnd = false
        if let currentTrack = self.currentTrack {
            self.logger.info("Track ended with repeat one and no queue; replaying current track")
            await self.play(song: currentTrack, webLoadStrategy: .preferInPlaceWhenSameVideoId)
            return
        }

        if let pendingVideoId = self.pendingPlayVideoId {
            self.logger.info("Track ended with repeat one and no queue metadata; replaying pending video")
            await self.play(videoId: pendingVideoId)
            return
        }
    }

    /// Handles a natural track completion reported directly by the WebView.
    func handleTrackEnded(observedVideoId: String?) async {
        self.logger.debug("Track ended reported by WebView: \(observedVideoId ?? "unknown")")
        self.songNearingEnd = false
        guard !self.queue.isEmpty else {
            if self.repeatMode == .one, self.currentTrack != nil || self.pendingPlayVideoId != nil {
                await self.replayCurrentSongForRepeatOneWithoutQueueAfterTrackEnd()
                return
            }
            self.markPlaybackEnded()
            return
        }
        if let observedVideoId = self.normalizedObservedVideoId(observedVideoId) {
            let currentQueueVideoId = self.queue[safe: self.currentIndex]?.videoId
            let expectedCurrentVideoId = currentQueueVideoId ?? self.currentTrack?.videoId ?? self.pendingPlayVideoId
            if let expectedCurrentVideoId, expectedCurrentVideoId != observedVideoId {
                // Late duplicate `ended` events should not advance the queue twice. The only mismatch
                // we allow is repeat-all wrapping from the last queue item back to the first song.
                if self.repeatMode == .one {
                    self.logger.info(
                        "Track ended: observed \(observedVideoId) != queue \(expectedCurrentVideoId) while repeat one is active; replaying current queue song"
                    )
                } else if self.isRepeatAllWraparoundTrackEnd(
                    observedVideoId: observedVideoId,
                    expectedCurrentVideoId: expectedCurrentVideoId
                ) {
                    self.logger.info(
                        "Track ended: observed \(observedVideoId) already wrapped from queue \(expectedCurrentVideoId); applying repeat-all wraparound"
                    )
                } else {
                    self.logger.debug(
                        "Ignoring stale track-ended event for \(observedVideoId); current queue track is \(expectedCurrentVideoId)"
                    )
                    return
                }
            }
        }

        guard self.canAdvanceNativeQueueAfterTrackEnd else {
            self.shouldSuppressAutoplayAfterQueueEnd = true
            self.markPlaybackEnded()
            self.logger.info("Reached end of native queue; not yielding to YouTube autoplay")
            await self.pause()
            return
        }
        self.shouldSuppressAutoplayAfterQueueEnd = false
        if self.repeatMode == .one {
            self.logger.info("Track ended with repeat one; replaying current queue song")
            await self.replayCurrentQueueSongForRepeatOneAfterTrackEnd()
            return
        }

        // Check if the next expected track was already injected into the web queue.
        // If so, YouTube Music will auto-advance to it natively — we just need to
        // update our internal state without triggering another loadVideo navigation.
        if let expectedIndex = self.expectedQueueIndexAfterCurrentTrack(),
           let expectedSong = self.queue[safe: expectedIndex],
           self.injectedWebQueueVideoId == expectedSong.videoId
        {
            self.logger.info("Track ended natively. Injected track \(expectedSong.videoId) will auto-play; advancing queue index only.")
            self.injectedWebQueueVideoId = nil
            self.pushForwardSkipStackIfLeavingIndex(for: expectedIndex)
            self.currentIndex = expectedIndex
            self.currentTrack = expectedSong
            self.isKasetInitiatedPlayback = true
            self.resetTrackStatus()
            if let cachedStatus = SongLikeStatusManager.shared.status(for: expectedSong.videoId) {
                self.currentTrackLikeStatus = cachedStatus
            }
            self.saveQueueForPersistence()
            // Pre-inject the *next* next track for the following transition
            self.syncWebQueue()
            return
        }

        self.logger.info("Track ended in WebView, advancing native queue immediately")
        await self.next()
    }

    /// Updates track metadata and enforces Kaset's queue when YouTube tries to diverge.
    func updateTrackMetadata(title: String, artist: String, thumbnailUrl: String, videoId observedVideoId: String?) {
        self.logger.debug("Track metadata updated: \(title) - \(artist)")

        let isRestoringFromCloud = self.queue.isEmpty && !self.isKasetInitiatedPlayback && observedVideoId != nil

        if self.isPendingRestoredLoadDeferred || isRestoringFromCloud {
            self.applyDeferredRestoredMetadata(
                title: title,
                artist: artist,
                thumbnailUrl: thumbnailUrl,
                videoId: observedVideoId
            )
            return
        }

        let thumbnailURL = URL(string: thumbnailUrl)
        let artistObj = Artist(id: "unknown", name: artist)
        let resolvedVideoId = self.resolvedObservedVideoId(observedVideoId)
        let trackChanged = self.currentTrack?.title != title
            || self.currentTrack?.artistsDisplay != artist
            || self.currentTrack?.videoId != resolvedVideoId

        if self.suppressUnexpectedAutoplayAfterQueueEndIfNeeded(
            trackChanged: trackChanged,
            observedVideoId: observedVideoId,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl
        ) {
            return
        }

        if self.handleKasetInitiatedPlaybackMetadata(
            observedVideoId: observedVideoId,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            trackChanged: trackChanged
        ) {
            return
        }

        if self.handleNearEndTrackChangeIfNeeded(
            observedVideoId: observedVideoId,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            trackChanged: trackChanged
        ) {
            return
        }

        if self.handleUnexpectedQueueDriftIfNeeded(
            observedVideoId: observedVideoId,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            trackChanged: trackChanged
        ) {
            return
        }

        if self.finalRepeatOneSafetyNetIfNeeded(
            observedVideoId: observedVideoId,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            trackChanged: trackChanged
        ) {
            return
        }

        // Repeat one: never replace the queue-driven `currentTrack` with YouTube's row (autoplay after idle/end).
        if self.repeatMode == .one, let queued = self.queue[safe: self.currentIndex] {
            self.keepQueueSongVisible(queued, thumbnailUrl: thumbnailUrl)
            return
        }

        self.currentTrack = Song(
            id: resolvedVideoId,
            title: title,
            artists: [artistObj],
            album: nil,
            duration: self.duration > 0 ? self.duration : nil,
            thumbnailURL: thumbnailURL,
            videoId: resolvedVideoId
        )

        if trackChanged {
            self.resetTrackStatus()
            // Immediately restore like status from SongLikeStatusManager cache
            if let cachedStatus = SongLikeStatusManager.shared.status(for: resolvedVideoId) {
                self.currentTrackLikeStatus = cachedStatus
            }

            // Re-sync the web queue since the track changed natively
            self.syncWebQueue()
        }
    }
}
