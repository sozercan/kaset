import Foundation

// MARK: - Web Queue Sync

@MainActor
extension PlayerService {
    private static let queueNavigationInFlightProtectionGrace: Duration = .seconds(20)
    private static let queueNavigationConfirmedProtectionGrace: Duration = .seconds(8)
    private static let webQueueInjectionTimeout: Duration = .seconds(20)

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
        if previousVideoId != observedVideoId {
            // The saved seek belongs to the persisted track, not a different server-restored track.
            self.pendingRestoredSeek = nil
        }

        // Sync the web view's current video ID so Kaset knows the player is already on this track
        SingletonPlayerWebView.shared.currentVideoId = observedVideoId
        if observedVideoId == previousVideoId, !self.queue.isEmpty {
            Task {
                await self.fetchSongMetadata(videoId: observedVideoId)
            }
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
    /// Injecting the next track ahead of time enables best-effort gapless playback when the current track ends.
    ///
    /// **Important:** Only runs when the player is in a stable state (`.playing` or `.paused`).
    /// During `.loading` or a main-document navigation, the player bar DOM is in flux.
    /// Injection is deferred until playback is stable or the navigation delegate reports
    /// that the replacement document has finished loading.
    func syncWebQueue() {
        // Never manipulate the player-bar menu while its document is being replaced.
        guard self.state == .playing || self.state == .paused else { return }
        guard !SingletonPlayerWebView.shared.isDocumentNavigationInProgress else { return }

        guard let nextIndex = self.expectedQueueIndexAfterCurrentTrack(),
              let nextSong = self.queue[safe: nextIndex],
              let sourceVideoId = self.expectedPlaybackVideoId
        else {
            self.clearWebQueueInjectionState()
            return
        }

        guard self.injectedWebQueueVideoId != nextSong.videoId,
              self.pendingWebQueueInjectionVideoId != nextSong.videoId
        else { return }

        // Duplicate video IDs need an explicit in-place restart so the media
        // generation advances with the queue entry. Do not trust native Up Next
        // for a same-ID transition.
        guard nextSong.videoId != sourceVideoId else {
            self.clearWebQueueInjectionState()
            return
        }

        self.pendingWebQueueInjectionVideoId = nextSong.videoId
        self.webQueueInjectionGeneration &+= 1
        let injectionGeneration = self.webQueueInjectionGeneration
        if SingletonPlayerWebView.shared.injectNextSong(
            videoId: nextSong.videoId,
            afterVideoId: sourceVideoId,
            attemptGeneration: injectionGeneration
        ) {
            self.logger.info("Syncing web queue: requested injection of \(nextSong.videoId) to play next natively")
            self.scheduleWebQueueInjectionTimeout(
                videoId: nextSong.videoId,
                generation: injectionGeneration
            )
        } else {
            self.pendingWebQueueInjectionVideoId = nil
        }
    }

    private func scheduleWebQueueInjectionTimeout(videoId: String, generation: Int) {
        Task {
            try? await Task.sleep(for: Self.webQueueInjectionTimeout)
            guard self.webQueueInjectionGeneration == generation,
                  self.pendingWebQueueInjectionVideoId == videoId
            else {
                return
            }
            self.webQueueInjectionGeneration &+= 1
            self.pendingWebQueueInjectionVideoId = nil
            SingletonPlayerWebView.shared.cancelQueueInjection()
            self.logger.warning("Web queue injection timed out for \(videoId)")
        }
    }

    /// Records the WebView result for an attempted native queue injection.
    func handleWebQueueInjectionResult(
        videoId: String,
        attemptGeneration: Int,
        success: Bool,
        reason: String?
    ) {
        guard self.webQueueInjectionGeneration == attemptGeneration,
              self.pendingWebQueueInjectionVideoId == videoId
        else {
            self.logger.debug("Ignoring web queue injection result for non-pending video \(videoId)")
            return
        }
        self.webQueueInjectionGeneration &+= 1
        self.pendingWebQueueInjectionVideoId = nil

        guard success, reason == "queue-readback-confirmed" else {
            if self.injectedWebQueueVideoId == videoId {
                self.injectedWebQueueVideoId = nil
            }
            self.logger.warning("Web queue injection failed for \(videoId): \(reason ?? "unknown")")
            return
        }

        guard let nextIndex = self.expectedQueueIndexAfterCurrentTrack(),
              self.queue[safe: nextIndex]?.videoId == videoId
        else {
            if self.injectedWebQueueVideoId == videoId {
                self.injectedWebQueueVideoId = nil
            }
            self.logger.debug("Ignoring stale web queue injection confirmation for \(videoId)")
            return
        }

        self.injectedWebQueueVideoId = videoId
        self.logger.info("Synced web queue: confirmed \(videoId) to play next natively")
    }

    private var canAdvanceNativeQueueAfterTrackEnd: Bool {
        self.shuffleEnabled
            || self.repeatMode == .one
            || self.currentIndex < self.queue.count - 1
            || self.repeatMode == .all
            || self.mixContinuationToken != nil
    }

    func expectedQueueIndexAfterCurrentTrack() -> Int? {
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

    func protectQueueNavigationTarget(_ videoId: String) {
        self.protectedQueueNavigationVideoId = videoId
        self.protectedQueueNavigationStartedAt = ContinuousClock.now
        self.protectedQueueNavigationConfirmedAt = nil
    }

    private func confirmQueueNavigationTarget(_ videoId: String) {
        guard self.protectedQueueNavigationVideoId == videoId else { return }
        if self.protectedQueueNavigationConfirmedAt == nil {
            self.protectedQueueNavigationConfirmedAt = ContinuousClock.now
        }
    }

    @discardableResult
    private func clearExpiredQueueNavigationProtectionIfNeeded() -> Bool {
        let now = ContinuousClock.now
        if let confirmedAt = self.protectedQueueNavigationConfirmedAt {
            guard now - confirmedAt >= Self.queueNavigationConfirmedProtectionGrace else { return false }
        } else if let startedAt = self.protectedQueueNavigationStartedAt {
            guard now - startedAt >= Self.queueNavigationInFlightProtectionGrace else { return false }
        } else {
            return false
        }

        self.protectedQueueNavigationVideoId = nil
        self.protectedQueueNavigationStartedAt = nil
        self.protectedQueueNavigationConfirmedAt = nil
        return true
    }

    private func rejectProtectedQueueNavigationDriftIfNeeded(
        observedVideoId: String,
        currentQueueSong: Song,
        thumbnailUrl: String
    ) -> Bool {
        self.clearExpiredQueueNavigationProtectionIfNeeded()

        guard let normalizedObservedVideoId = self.normalizedObservedVideoId(observedVideoId),
              let protectedVideoId = self.protectedQueueNavigationVideoId,
              currentQueueSong.videoId == protectedVideoId,
              normalizedObservedVideoId != protectedVideoId
        else { return false }

        self.logger.info(
            "Ignoring stale in-queue metadata for \(normalizedObservedVideoId); keeping protected queue target \(protectedVideoId)"
        )
        self.keepQueueSongVisible(currentQueueSong, thumbnailUrl: thumbnailUrl)
        Task {
            await self.play(song: currentQueueSong, webLoadStrategy: .forceFullPageWhenSameVideoId)
        }
        return true
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
        if self.clearExpiredQueueNavigationProtectionIfNeeded() {
            self.isKasetInitiatedPlayback = false
        }

        guard self.isKasetInitiatedPlayback, !self.queue.isEmpty else {
            return false
        }

        guard let intendedSong = self.queue[safe: self.currentIndex] else {
            self.isKasetInitiatedPlayback = false
            return false
        }

        let matchesObservedVideo = self.normalizedObservedVideoId(observedVideoId) == intendedSong.videoId
        if matchesObservedVideo, self.shouldKeepQueueMetadata(title: title, artist: artist, song: intendedSong) {
            self.confirmQueueNavigationTarget(intendedSong.videoId)
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
            self.confirmQueueNavigationTarget(intendedSong.videoId)
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
        // Keep the Kaset-initiated guard active until the intended video is
        // actually confirmed. WebView metadata can emit multiple stale frames
        // for the previous/native queue item while our manual navigation load is
        // still in flight; dropping the guard here lets a later stale frame
        // realign `currentIndex` backward through `handleUnexpectedQueueDriftIfNeeded`.
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

        if self.rejectProtectedQueueNavigationDriftIfNeeded(
            observedVideoId: observedVideoId,
            currentQueueSong: currentQueueSong,
            thumbnailUrl: thumbnailUrl
        ) {
            return true
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
        if let pending = self.pendingNativeQueueAdvance {
            let normalizedEndedVideoId = self.normalizedObservedVideoId(observedVideoId)
            if normalizedEndedVideoId == pending.sourceVideoId {
                self.logger.debug("Ignoring duplicate ended event from native handoff source")
                return
            }
            guard normalizedEndedVideoId == pending.targetVideoId,
                  await self.reconcilePendingNativeQueueAdvanceObservation(
                      videoId: normalizedEndedVideoId
                  )
            else {
                if normalizedEndedVideoId != nil {
                    _ = await self.reconcilePendingNativeQueueAdvanceObservation(
                        videoId: normalizedEndedVideoId
                    )
                }
                return
            }
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

        // A readback-confirmed YouTube Music queue entry may advance without
        // navigation. Keep the outgoing song visible until the media-bound observer
        // confirms the exact expected target; a wrong or missing transition falls
        // back to deterministic loading after a short bounded wait.
        if let expectedIndex = self.expectedQueueIndexAfterCurrentTrack(),
           let expectedSong = self.queue[safe: expectedIndex],
           self.injectedWebQueueVideoId == expectedSong.videoId
        {
            self.logger.info(
                "Track ended with verified native next \(expectedSong.videoId); awaiting media confirmation"
            )
            self.injectedWebQueueVideoId = nil
            self.beginPendingNativeQueueAdvance(to: expectedIndex)
            return
        }

        self.logger.info("Track ended in WebView, advancing native queue immediately")
        await self.next()
    }

    /// Updates track metadata and enforces Kaset's queue when YouTube tries to diverge.
    func updateTrackMetadata(title: String, artist: String, thumbnailUrl: String, videoId observedVideoId: String?) {
        self.logger.debug("Track metadata updated: \(title) - \(artist)")

        let isRestoringFromCloud = self.isAwaitingWebRestoredTrack
            && !self.isKasetInitiatedPlayback
            && observedVideoId != nil

        if self.isPendingRestoredLoadDeferred {
            guard self.isAwaitingWebRestoredTrack else { return }
            self.applyDeferredRestoredMetadata(
                title: title,
                artist: artist,
                thumbnailUrl: thumbnailUrl,
                videoId: observedVideoId
            )
            return
        }

        if isRestoringFromCloud {
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
        let videoIdChanged = self.currentTrack?.videoId != resolvedVideoId
        let trackChanged = self.currentTrack?.title != title
            || self.currentTrack?.artistsDisplay != artist
            || videoIdChanged

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

            if videoIdChanged {
                self.clearWebQueueInjectionState()
                // Re-sync the web queue since the playing video changed natively.
                self.syncWebQueue()
            }
        }
    }
}
