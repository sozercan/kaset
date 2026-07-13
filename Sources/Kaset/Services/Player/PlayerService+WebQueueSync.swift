import Foundation

// MARK: - Web Queue Sync

@MainActor
extension PlayerService {
    /// Distance from `duration` at which a manual seek is treated as the end of the track.
    /// `video.currentTime = duration` does not reliably fire `ended` in WebKit, and a subsequent
    /// play call would restart the same song from 0 instead of advancing.
    static let seekToEndThreshold: TimeInterval = 0.5

    /// Routes a manual seek that landed at the end of the track through the track-ended path so
    /// repeat / queue / autoplay-suppression rules apply consistently with a natural end.
    func handleManualSeekToEnd() async {
        self.logger.info("Manual seek reached end of track; routing through track-ended path")
        guard self.claimTerminalMusicPlaybackOccurrence(self.currentMusicPlaybackOccurrence) else {
            self.logger.debug("Ignoring duplicate manual track-end transition for consumed playback occurrence")
            return
        }
        self.clearRestoredPlaybackSessionState()
        self.progress = self.duration

        if self.shouldSynchronizeWebViewForTerminalManualSeekToEnd {
            SingletonPlayerWebView.shared.seekAndPause(to: self.duration)
        }

        await self.finishTrackEnded(
            observedVideoId: self.currentTrack?.videoId,
            intent: self.currentMusicPlaybackIntent
        )
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

    var canAdvanceNativeQueueAfterTrackEnd: Bool {
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
            isPlayable: song.isPlayable,
            hasVideo: song.hasVideo,
            musicVideoType: song.musicVideoType,
            likeStatus: song.likeStatus,
            isInLibrary: song.isInLibrary,
            feedbackTokens: song.feedbackTokens,
            isExplicit: song.isExplicit
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
              self.activePlaybackOwnsCurrentQueueEntry,
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
        self.scheduleMusicPlaybackIntentTask(expectedQueueEntryID: self.currentQueueEntryID) { service, intent in
            await service.pause(intent: intent)
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
        guard self.isKasetInitiatedPlayback,
              !self.queue.isEmpty,
              self.activePlaybackOwnsCurrentQueueEntry
        else {
            return false
        }

        guard let intendedEntry = self.queueEntries[safe: self.currentIndex] else {
            self.isKasetInitiatedPlayback = false
            return false
        }
        let intendedSong = intendedEntry.song

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
        self.scheduleMusicPlaybackIntentTask(expectedQueueEntryID: intendedEntry.id) { service, intent in
            await service.play(
                song: intendedSong,
                webLoadStrategy: .forceFullPageWhenSameVideoId,
                queueEntryID: intendedEntry.id,
                intent: intent
            )
        }
        return true
    }

    // The occurrence token joins the existing observed metadata so the near-end
    // transition can be claimed atomically instead of advancing twice.
    // swiftlint:disable:next function_parameter_count
    private func handleNearEndTrackChangeIfNeeded(
        observedVideoId: String?,
        title: String,
        artist: String,
        thumbnailUrl: String,
        trackChanged: Bool,
        playbackOccurrence: MusicPlaybackOccurrence?
    ) -> Bool {
        guard trackChanged,
              !self.queue.isEmpty,
              self.songNearingEnd,
              self.activePlaybackOwnsCurrentQueueEntry
        else {
            return false
        }
        if let expectedNextIndex = self.expectedQueueIndexAfterCurrentTrack(),
           let expectedNextEntry = self.queueEntries[safe: expectedNextIndex],
           let currentEntry = self.queueEntries[safe: self.currentIndex],
           expectedNextEntry.song.videoId == currentEntry.song.videoId,
           self.queueEntries.count(where: { $0.song.videoId == expectedNextEntry.song.videoId }) > 1,
           self.observedTrackMatchesSong(
               observedVideoId: observedVideoId,
               title: title,
               artist: artist,
               song: expectedNextEntry.song
           )
        {
            self.logger.debug(
                "Deferring ambiguous same-video near-end handoff until a terminal/media transition"
            )
            self.keepQueueSongVisible(currentEntry.song, thumbnailUrl: thumbnailUrl)
            return true
        }
        // Claim before scheduling either corrective branch below. Those branches
        // deliberately own this terminal transition even when YouTube's observed
        // successor is not the queue's expected song; otherwise a queued `ended`
        // callback can race the unstructured corrective task and advance twice.
        guard self.claimTerminalMusicPlaybackOccurrence(playbackOccurrence) else {
            self.logger.debug("Ignoring duplicate near-end transition for consumed playback occurrence")
            return true
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
                    self.scheduleMusicPlaybackIntentTask(expectedQueueEntryID: self.currentQueueEntryID) { service, intent in
                        await service.replayCurrentQueueSongForRepeatOneAfterTrackEnd(intent: intent)
                    }
                    return true
                }
                self.logger.info("YouTube autoplay detected, overriding with queue track")
                self.scheduleMusicPlaybackIntentTask(expectedQueueEntryID: self.currentQueueEntryID) { service, intent in
                    await service.next(intent: intent)
                }
                return true
            }

            self.currentIndex = expectedNextIndex
            self.beginNativeMusicPlaybackOccurrence(
                videoId: expectedNextTrack.videoId,
                synchronizeCurrentDocument: true
            )
            self.activePlaybackQueueEntryID = self.currentQueueEntryID
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
                self.scheduleMusicPlaybackIntentTask(expectedQueueEntryID: self.currentQueueEntryID) { service, intent in
                    await service.replayCurrentQueueSongForRepeatOneAfterTrackEnd(intent: intent)
                }
                return true
            }
            self.logger.info("Near-end track change detected, advancing native queue to enforce playback order")
            self.scheduleMusicPlaybackIntentTask(expectedQueueEntryID: self.currentQueueEntryID) { service, intent in
                await service.next(intent: intent)
            }
            return true
        }

        self.markPlaybackEnded()
        self.logger.info("Unexpected autoplay detected at end of native queue; pausing playback")
        self.scheduleMusicPlaybackIntentTask(expectedQueueEntryID: self.currentQueueEntryID) { service, intent in
            await service.pause(intent: intent)
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
              self.activePlaybackOwnsCurrentQueueEntry,
              let queuedEntry = self.queueEntries[safe: self.currentIndex]
        else {
            return false
        }
        let queued = queuedEntry.song

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
        self.scheduleMusicPlaybackIntentTask(expectedQueueEntryID: queuedEntry.id) { service, intent in
            await service.play(
                song: queued,
                webLoadStrategy: .forceFullPageWhenSameVideoId,
                queueEntryID: queuedEntry.id,
                intent: intent
            )
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
              self.activePlaybackOwnsCurrentQueueEntry,
              let observedVideoId = self.normalizedObservedVideoId(observedVideoId),
              let currentQueueEntry = self.queueEntries[safe: self.currentIndex],
              currentQueueEntry.song.videoId != observedVideoId
        else {
            return false
        }
        let currentQueueSong = currentQueueEntry.song

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
            self.scheduleMusicPlaybackIntentTask(expectedQueueEntryID: currentQueueEntry.id) { service, intent in
                await service.play(
                    song: currentQueueSong,
                    webLoadStrategy: .forceFullPageWhenSameVideoId,
                    queueEntryID: currentQueueEntry.id,
                    intent: intent
                )
            }
            return true
        }

        let matchingEntries = self.queueEntries.enumerated().filter { $0.element.song.videoId == observedVideoId }
        if matchingEntries.count == 1, let match = matchingEntries.first {
            let matchingIndex = match.offset
            let matchingSong = match.element.song
            let queueIndexChanged = matchingIndex != self.currentIndex
            if queueIndexChanged {
                self.currentIndex = matchingIndex
                self.activePlaybackQueueEntryID = self.currentQueueEntryID
                self.logger.info("Observed playback moved to queue index \(matchingIndex), realigning native queue")
            }

            if queueIndexChanged || self.shouldKeepQueueMetadata(title: title, artist: artist, song: matchingSong) {
                if self.currentTrack?.videoId != matchingSong.videoId {
                    self.resetTrackStatus()
                    // Immediately restore like status from SongLikeStatusManager cache
                    if let cachedStatus = self.songLikeStatusManager.status(for: matchingSong.videoId) {
                        self.currentTrackLikeStatus = cachedStatus
                    }
                }
                self.keepQueueSongVisible(matchingSong, thumbnailUrl: thumbnailUrl)
                if queueIndexChanged {
                    self.saveQueueForPersistence()
                }
                return true
            }
            return false
        }

        self.logger.info(
            "Observed track \(observedVideoId) diverged from native queue track \(currentQueueSong.videoId); re-playing intended queue track"
        )
        self.scheduleMusicPlaybackIntentTask(expectedQueueEntryID: currentQueueEntry.id) { service, intent in
            await service.play(
                song: currentQueueSong,
                webLoadStrategy: .forceFullPageWhenSameVideoId,
                queueEntryID: currentQueueEntry.id,
                intent: intent
            )
        }
        return true
    }

    /// Replays the current queue song after a natural `ended` event. User-initiated **Next** uses ``PlayerService/next()`` instead.
    private func replayCurrentQueueSongForRepeatOneAfterTrackEnd(intent: MusicPlaybackIntent) async {
        guard self.acceptsMusicPlaybackIntent(intent),
              let currentEntry = self.queueEntries[safe: self.currentIndex]
        else { return }
        let currentSong = currentEntry.song
        self.songNearingEnd = false
        let kasetAlignedWithQueue = self.pendingPlayVideoId == currentSong.videoId
            && self.currentWebPlaybackVideoId() == currentSong.videoId
        if self.hasUserInteractedThisSession, kasetAlignedWithQueue {
            self.beginNativeMusicPlaybackOccurrence(
                videoId: currentSong.videoId,
                synchronizeCurrentDocument: true
            )
            self.activePlaybackQueueEntryID = self.currentQueueEntryID
            self.resetAdPlaybackState()
            self.progress = 0
            self.currentTimeMs = 0
            self.shouldResumeAfterInterruption = true
            self.isAwaitingPlaybackConfirmation = true
            self.isExplicitPauseIntentActive = false
            SingletonPlayerWebView.shared.restartInPlaceFromBeginning()
            if self.state == .ended || self.state == .loading {
                self.state = .playing
            }
        } else {
            await self.play(
                song: currentSong,
                webLoadStrategy: .preferInPlaceWhenSameVideoId,
                queueEntryID: currentEntry.id,
                intent: intent
            )
        }
    }

    /// Replays the currently playing song for repeat-one when no native queue is active.
    private func replayCurrentSongForRepeatOneWithoutQueueAfterTrackEnd(
        intent: MusicPlaybackIntent
    ) async {
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        self.songNearingEnd = false
        if let currentTrack = self.currentTrack {
            self.logger.info("Track ended with repeat one and no queue; replaying current track")
            await self.play(
                song: currentTrack,
                webLoadStrategy: .preferInPlaceWhenSameVideoId,
                queueEntryID: nil,
                intent: intent
            )
            return
        }

        if let pendingVideoId = self.pendingPlayVideoId {
            self.logger.info("Track ended with repeat one and no queue metadata; replaying pending video")
            await self.play(videoId: pendingVideoId, intent: intent)
            return
        }
    }

    /// Handles a natural track completion reported directly by the WebView.
    func handleTrackEnded(
        observedVideoId: String?,
        playbackOccurrence: MusicPlaybackOccurrence? = nil,
        intent suppliedIntent: MusicPlaybackIntent? = nil
    ) async {
        let intent = suppliedIntent ?? self.currentMusicPlaybackIntent
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        self.logger.debug("Track ended reported by WebView: \(observedVideoId ?? "unknown")")
        guard self.claimTerminalMusicPlaybackOccurrence(playbackOccurrence) else {
            self.logger.debug("Ignoring duplicate track-ended transition for consumed playback occurrence")
            return
        }
        guard !self.isExplicitPauseIntentActive else {
            self.songNearingEnd = false
            self.logger.debug("Consumed track-ended transition without advancing because pause intent is active")
            return
        }
        await self.finishTrackEnded(observedVideoId: observedVideoId, intent: intent)
    }

    private func finishTrackEnded(
        observedVideoId: String?,
        intent: MusicPlaybackIntent
    ) async {
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        self.songNearingEnd = false
        guard self.activePlaybackOwnsCurrentQueueEntry,
              !self.queue.isEmpty
        else {
            if self.repeatMode == .one, self.currentTrack != nil || self.pendingPlayVideoId != nil {
                await self.replayCurrentSongForRepeatOneWithoutQueueAfterTrackEnd(intent: intent)
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
            await self.pause(intent: intent)
            return
        }
        self.shouldSuppressAutoplayAfterQueueEnd = false
        if self.repeatMode == .one {
            self.logger.info("Track ended with repeat one; replaying current queue song")
            await self.replayCurrentQueueSongForRepeatOneAfterTrackEnd(intent: intent)
            return
        }
        self.logger.info("Track ended in WebView, advancing native queue immediately")
        await self.next(intent: intent)
    }

    /// Updates track metadata and enforces Kaset's queue when YouTube tries to diverge.
    func updateTrackMetadata(title: String, artist: String, thumbnailUrl: String, videoId observedVideoId: String?) {
        self.updateTrackMetadata(
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            videoId: observedVideoId,
            playbackOccurrence: self.currentMusicPlaybackOccurrence
        )
    }

    func updateTrackMetadata(
        title: String,
        artist: String,
        thumbnailUrl: String,
        videoId observedVideoId: String?,
        playbackOccurrence: MusicPlaybackOccurrence?
    ) {
        self.logger.debug("Track metadata updated: \(title) - \(artist)")
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
            trackChanged: trackChanged,
            playbackOccurrence: playbackOccurrence
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
            if let cachedStatus = self.songLikeStatusManager.status(for: resolvedVideoId) {
                self.currentTrackLikeStatus = cachedStatus
            }
        }
    }
}
