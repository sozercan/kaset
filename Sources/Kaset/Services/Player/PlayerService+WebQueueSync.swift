// swiftlint:disable file_length

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
        guard let observedVideoId = self.normalizedPlaybackVideoId(observedVideoId) else { return }

        let thumbnailURL = URL(string: thumbnailUrl)
        let normalizedArtistName = Self.normalizedWebArtistName(artist)
        let artistObj = Artist(id: "unknown", name: normalizedArtistName)
        let matchedQueueEntry = self.queueEntries.first(where: { $0.song.videoId == observedVideoId })
        let matchedQueueSong = matchedQueueEntry?.song
        let seedSong: Song

        let previousVideoId = self.currentTrack?.videoId
        self.pendingPlayVideoId = observedVideoId
        self.isKasetInitiatedPlayback = false
        self.isAwaitingWebRestoredTrack = false
        if previousVideoId != observedVideoId {
            // The saved seek belongs to the persisted track, not a different server-restored track.
            self.pendingRestoredSeek = nil
            self.progress = 0
            self.duration = matchedQueueSong?.duration ?? 0
        }

        // Sync the web view's current video ID so Kaset knows the player is already on this track
        SingletonPlayerWebView.shared.currentVideoId = observedVideoId
        if observedVideoId == previousVideoId, !self.queue.isEmpty {
            let queueEntryID = self.currentQueueEntryID
            Task { [queueEntryID] in
                await self.fetchSongMetadata(
                    videoId: observedVideoId,
                    queueOwner: queueEntryID.map(MusicQueueMetadataOwner.entry) ?? .none
                )
            }
            return
        }
        self.mixContinuationToken = nil

        if let matchedQueueSong,
           self.shouldKeepQueueMetadata(
               title: title,
               artist: normalizedArtistName,
               song: matchedQueueSong
           )
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
        if let matchedQueueEntry {
            self.setQueue(entries: [
                QueueEntry(
                    id: matchedQueueEntry.id,
                    song: seedSong,
                    source: matchedQueueEntry.source
                ),
            ])
        } else {
            self.setQueue([seedSong])
        }
        self.currentIndex = 0
        self.synchronizeCurrentQueueEntryID()
        self.activePlaybackQueueEntryID = self.currentQueueEntryID
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
            if let cachedStatus = self.songLikeStatusManager.status(for: observedVideoId) {
                self.currentTrackLikeStatus = cachedStatus
            }
            let queueEntryID = self.currentQueueEntryID
            Task { [queueEntryID] in
                await self.fetchSongMetadata(
                    videoId: observedVideoId,
                    queueOwner: queueEntryID.map(MusicQueueMetadataOwner.entry) ?? .none
                )
            }
        }
    }

    private func resolvedObservedVideoId(_ videoId: String?) -> String {
        self.normalizedPlaybackVideoId(videoId) ?? self.currentTrack?.videoId ?? self.pendingPlayVideoId ?? "unknown"
    }

    private func observedTrackMatchesSong(
        observedVideoId: String?,
        title: String,
        artist: String,
        song: Song
    ) -> Bool {
        if let observedVideoId = self.normalizedPlaybackVideoId(observedVideoId) {
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
        guard self.activePlaybackOwnsCurrentQueueEntry else {
            self.clearWebQueueInjectionState()
            return
        }

        guard let nextIndex = self.expectedQueueIndexAfterCurrentTrack(),
              let nextSong = self.queue[safe: nextIndex],
              let sourceVideoId = self.expectedPlaybackVideoId
        else {
            self.clearWebQueueInjectionState()
            return
        }

        // Duplicate video IDs need an explicit in-place restart so the media
        // generation advances with the queue entry. Clear any marker consumed by
        // the preceding occurrence before checking cached target IDs.
        guard nextSong.videoId != sourceVideoId else {
            self.clearWebQueueInjectionState()
            return
        }

        let confirmedTargetChanged = self.injectedWebQueueVideoId.map { $0 != nextSong.videoId } ?? false
        let pendingTargetChanged = self.pendingWebQueueInjectionVideoId.map { $0 != nextSong.videoId } ?? false
        if confirmedTargetChanged || pendingTargetChanged {
            self.clearWebQueueInjectionState()
        }

        guard self.injectedWebQueueVideoId != nextSong.videoId,
              self.pendingWebQueueInjectionVideoId != nextSong.videoId
        else { return }

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
              self.pendingWebQueueInjectionVideoId == videoId,
              self.activePlaybackOwnsCurrentQueueEntry
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

    var canAdvanceNativeQueueAfterTrackEnd: Bool {
        self.activePlaybackOwnsCurrentQueueEntry
            && (
                self.repeatMode == .one
                    || self.currentIndex < self.queue.count - 1
                    || self.repeatMode == .all
                    || self.mixContinuationToken != nil
            )
    }

    func expectedQueueIndexAfterCurrentTrack() -> Int? {
        guard !self.queue.isEmpty else { return nil }
        if self.repeatMode == .one {
            return self.currentIndex
        }
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

        guard let normalizedObservedVideoId = self.normalizedPlaybackVideoId(observedVideoId),
              let protectedVideoId = self.protectedQueueNavigationVideoId,
              currentQueueSong.videoId == protectedVideoId,
              normalizedObservedVideoId != protectedVideoId
        else { return false }

        self.logger.info(
            "Ignoring stale in-queue metadata for \(normalizedObservedVideoId); keeping protected queue target \(protectedVideoId)"
        )
        self.keepQueueSongVisible(currentQueueSong, thumbnailUrl: thumbnailUrl)
        self.scheduleQueueNavigationRecovery(for: currentQueueSong)
        return true
    }

    private func isRepeatAllWraparoundTrackEnd(
        observedVideoId: String,
        expectedCurrentVideoId: String
    ) -> Bool {
        guard self.repeatMode == .all,
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
        self.currentTrack = song.replacingDisplayMetadata(
            title: song.title,
            artists: song.artists,
            thumbnailURL: intendedThumbnailURL
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
        if self.clearExpiredQueueNavigationProtectionIfNeeded() {
            self.isKasetInitiatedPlayback = false
            self.clearQueueNavigationRecovery()
        }

        guard self.isKasetInitiatedPlayback,
              !self.queue.isEmpty,
              self.activePlaybackOwnsCurrentQueueEntry
        else {
            return false
        }

        guard let intendedEntry = self.queueEntries[safe: self.currentIndex] else {
            self.isKasetInitiatedPlayback = false
            self.clearQueueNavigationRecovery()
            return false
        }
        let intendedSong = intendedEntry.song

        let matchesObservedVideo = self.normalizedPlaybackVideoId(observedVideoId) == intendedSong.videoId
        if matchesObservedVideo, self.shouldKeepQueueMetadata(title: title, artist: artist, song: intendedSong) {
            self.confirmQueueNavigationTarget(intendedSong.videoId)
            self.isKasetInitiatedPlayback = false
            self.clearQueueNavigationRecovery()
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
            self.clearQueueNavigationRecovery()
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
        self.scheduleQueueNavigationRecovery(for: intendedSong)
        return true
    }

    func handleRejectedQueueNavigationObservationIfNeeded(
        observedVideoId: String?,
        title: String,
        artist: String,
        thumbnailUrl: String,
        trackChanged: Bool
    ) {
        guard self.isKasetInitiatedPlayback,
              let intendedSong = self.queue[safe: self.currentIndex],
              self.protectedQueueNavigationVideoId == intendedSong.videoId,
              let observedVideoId = self.normalizedPlaybackVideoId(observedVideoId),
              observedVideoId != intendedSong.videoId
        else { return }
        _ = self.handleKasetInitiatedPlaybackMetadata(
            observedVideoId: observedVideoId,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            trackChanged: trackChanged
                || self.normalizedPlaybackVideoId(observedVideoId) != intendedSong.videoId
        )
    }

    private func commitObservedQueueTrack(
        to index: Int,
        videoId: String,
        beginsPlaybackOccurrence: Bool = false
    ) {
        self.clearWebQueueInjectionState()
        self.clearPendingNativeQueueAdvance()
        self.pushForwardSkipStackIfLeavingIndex(for: index)
        self.advanceQueueStateForNativeNavigation(to: index)
        if beginsPlaybackOccurrence {
            self.beginNativeMusicPlaybackOccurrence(
                videoId: videoId,
                synchronizeCurrentDocument: true
            )
            self.activePlaybackQueueEntryID = self.currentQueueEntryID
        }
        SingletonPlayerWebView.shared.currentVideoId = videoId
        self.saveQueueForPersistence(syncWebQueue: false)
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
                    _ = await service.performNextNavigation(intent: intent)
                }
                return true
            }

            self.commitObservedQueueTrack(
                to: expectedNextIndex,
                videoId: expectedNextTrack.videoId,
                beginsPlaybackOccurrence: true
            )
            self.logger.info("Track advanced to queue index \(expectedNextIndex)")

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
                _ = await service.performNextNavigation(intent: intent)
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

        let observedNorm = self.normalizedPlaybackVideoId(observedVideoId)
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
              let observedVideoId = self.normalizedPlaybackVideoId(observedVideoId),
              let currentQueueEntry = self.queueEntries[safe: self.currentIndex],
              currentQueueEntry.song.videoId != observedVideoId
        else {
            return false
        }
        let currentQueueSong = currentQueueEntry.song

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
                self.commitObservedQueueTrack(to: matchingIndex, videoId: observedVideoId)
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
    private func replayCurrentQueueSongForRepeatOneAfterTrackEnd(
        intent: MusicPlaybackIntent,
        startsPaused: Bool = false
    ) async {
        guard self.acceptsMusicPlaybackIntent(intent),
              let currentEntry = self.queueEntries[safe: self.currentIndex]
        else { return }
        let currentSong = currentEntry.song
        self.songNearingEnd = false
        if startsPaused {
            await self.play(
                song: currentSong,
                webLoadStrategy: .forceFullPageWhenSameVideoId,
                queueEntryID: currentEntry.id,
                startsPaused: true,
                intent: intent
            )
            return
        }
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
        intent: MusicPlaybackIntent,
        startsPaused: Bool = false
    ) async {
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        self.songNearingEnd = false
        if let currentTrack = self.currentTrack {
            self.logger.info("Track ended with repeat one and no queue; replaying current track")
            await self.play(
                song: currentTrack,
                webLoadStrategy: startsPaused ? .forceFullPageWhenSameVideoId : .preferInPlaceWhenSameVideoId,
                queueEntryID: nil,
                startsPaused: startsPaused,
                intent: intent
            )
            return
        }

        if let pendingVideoId = self.pendingPlayVideoId {
            self.logger.info("Track ended with repeat one and no queue metadata; replaying pending video")
            if startsPaused {
                self.beginNativeMusicPlaybackOccurrence(
                    videoId: pendingVideoId,
                    synchronizeCurrentDocument: true
                )
                self.progress = 0
                self.currentTimeMs = 0
                self.shouldResumeAfterInterruption = false
                self.isAwaitingPlaybackConfirmation = false
                self.isExplicitPauseIntentActive = true
                self.state = .paused
                SingletonPlayerWebView.shared.setAutoplayBlocked(true)
                SingletonPlayerWebView.shared.seekAndPause(to: 0)
            } else {
                await self.play(videoId: pendingVideoId, intent: intent)
            }
            return
        }
    }

    private func acceptedTrackEndContinuationIntent(
        originalIntent: MusicPlaybackIntent,
        occurrence: MusicPlaybackOccurrence?
    ) -> MusicPlaybackIntent? {
        if self.acceptsMusicPlaybackIntent(originalIntent) {
            return originalIntent
        }

        guard self.musicPlaybackIntentAcceptsPriorTerminalEvent,
              originalIntent.generation >= self.musicPlaybackMinimumAcceptedTerminalIntentGeneration,
              originalIntent.generation <= self.musicPlaybackIntentGeneration,
              let occurrence,
              occurrence == self.currentMusicPlaybackOccurrence
        else {
            return nil
        }
        return self.currentMusicPlaybackIntent
    }

    private func restoreTrackEndQueueOwnershipAfterMaintenanceIfNeeded(
        sourceEntryID: UUID?,
        observedVideoId: String?,
        maintenanceGeneration: Int
    ) -> UUID? {
        guard maintenanceGeneration == self.nativeQueueMaintenanceGeneration,
              self.expectedQueueIndexAfterCurrentTrack() != nil,
              let sourceEntryID,
              !self.queueEntryIDs.contains(sourceEntryID),
              self.activePlaybackQueueEntryID == nil || self.activePlaybackQueueEntryID == sourceEntryID,
              let observedVideoId = self.normalizedPlaybackVideoId(observedVideoId),
              self.currentTrack?.videoId == observedVideoId,
              let currentEntry = self.queueEntries[safe: self.currentIndex],
              currentEntry.song.videoId == observedVideoId,
              self.queueEntries.count(where: { $0.song.videoId == observedVideoId }) == 1
        else {
            return nil
        }

        self.activePlaybackQueueEntryID = currentEntry.id
        return currentEntry.id
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    /// Handles a natural track completion reported directly by the WebView.
    func handleTrackEnded(
        observedVideoId: String?,
        playbackOccurrence: MusicPlaybackOccurrence? = nil,
        intent suppliedIntent: MusicPlaybackIntent? = nil,
        startsPaused suppliedStartsPaused: Bool? = nil,
        shouldContinue: @MainActor () -> Bool = { true }
    ) async {
        let intent = suppliedIntent ?? self.currentMusicPlaybackIntent
        guard shouldContinue(), self.acceptsMusicPlaybackIntent(intent) else { return }
        self.logger.debug("Track ended reported by WebView: \(observedVideoId ?? "unknown")")

        let normalizedEndedVideoId = self.normalizedPlaybackVideoId(observedVideoId)
        let defersOccurrenceClaimForPendingTarget = playbackOccurrence == nil
            && self.pendingNativeQueueAdvance.map { $0.targetVideoId == normalizedEndedVideoId } == true
        var terminalOccurrence = playbackOccurrence ?? self.currentMusicPlaybackOccurrence
        if !defersOccurrenceClaimForPendingTarget {
            guard self.claimTerminalMusicPlaybackOccurrence(playbackOccurrence) else {
                self.logger.debug("Ignoring duplicate track-ended transition for consumed playback occurrence")
                return
            }
            terminalOccurrence = playbackOccurrence ?? self.currentMusicPlaybackOccurrence
        }

        guard suppliedStartsPaused != nil || !self.isExplicitPauseIntentActive else {
            self.songNearingEnd = false
            self.logger.debug("Consumed track-ended transition without advancing because pause intent is active")
            return
        }
        let startsPaused = suppliedStartsPaused ?? self.isExplicitPauseIntentActive
        await self.finishTrackEnded(
            observedVideoId: observedVideoId,
            intent: intent,
            terminalOccurrence: terminalOccurrence,
            claimsPendingTargetOccurrence: defersOccurrenceClaimForPendingTarget,
            startsPaused: startsPaused,
            shouldContinue: shouldContinue
        )
    }

    // swiftlint:disable:next function_parameter_count
    private func finishTrackEnded(
        observedVideoId: String?,
        intent: MusicPlaybackIntent,
        terminalOccurrence suppliedTerminalOccurrence: MusicPlaybackOccurrence?,
        claimsPendingTargetOccurrence: Bool,
        startsPaused: Bool,
        shouldContinue: @MainActor () -> Bool
    ) async {
        guard shouldContinue(),
              let acceptedIntent = self.acceptedTrackEndContinuationIntent(
                  originalIntent: intent,
                  occurrence: suppliedTerminalOccurrence
              )
        else { return }
        var continuationIntent = acceptedIntent
        var terminalOccurrence = suppliedTerminalOccurrence
        var endedNavigationContext = self.playbackNavigationContext
        var endedEntryID = self.queueEntryIDOwningCurrentPlayback
        while !self.queue.isEmpty,
              self.expectedQueueIndexAfterCurrentTrack() == nil,
              self.nativeQueueMaintenanceTask != nil
        {
            let maintenanceGeneration = self.nativeQueueMaintenanceGeneration
            await self.awaitNativeQueueMaintenanceIfNeeded(generation: maintenanceGeneration)
            guard shouldContinue(),
                  let refreshedIntent = self.acceptedTrackEndContinuationIntent(
                      originalIntent: intent,
                      occurrence: terminalOccurrence
                  ),
                  self.playbackNavigationContext == endedNavigationContext
            else { return }
            continuationIntent = refreshedIntent
            if let reboundEntryID = self.restoreTrackEndQueueOwnershipAfterMaintenanceIfNeeded(
                sourceEntryID: endedEntryID,
                observedVideoId: observedVideoId,
                maintenanceGeneration: maintenanceGeneration
            ) {
                endedEntryID = reboundEntryID
            }
        }

        self.songNearingEnd = false
        guard self.activePlaybackOwnsCurrentQueueEntry,
              !self.queue.isEmpty
        else {
            if self.repeatMode == .one, self.currentTrack != nil || self.pendingPlayVideoId != nil {
                await self.replayCurrentSongForRepeatOneWithoutQueueAfterTrackEnd(
                    intent: continuationIntent,
                    startsPaused: startsPaused
                )
                return
            }
            self.markPlaybackEnded()
            return
        }

        if let pending = self.pendingNativeQueueAdvance {
            let normalizedEndedVideoId = self.normalizedPlaybackVideoId(observedVideoId)
            if normalizedEndedVideoId == pending.sourceVideoId {
                self.logger.debug("Ignoring duplicate ended event from native handoff source")
                return
            }

            let didReconcileTarget: Bool
            if normalizedEndedVideoId == pending.targetVideoId {
                didReconcileTarget = await self.reconcilePendingNativeQueueAdvanceObservation(
                    videoId: normalizedEndedVideoId
                )
            } else {
                if normalizedEndedVideoId != nil {
                    _ = await self.reconcilePendingNativeQueueAdvanceObservation(
                        videoId: normalizedEndedVideoId
                    )
                }
                didReconcileTarget = false
            }
            guard shouldContinue(), didReconcileTarget else { return }

            if claimsPendingTargetOccurrence {
                let targetOccurrence = self.beginNativeMusicPlaybackOccurrence(
                    videoId: normalizedEndedVideoId,
                    synchronizeCurrentDocument: true
                )
                guard self.claimTerminalMusicPlaybackOccurrence(targetOccurrence) else { return }
                terminalOccurrence = targetOccurrence
            }
            guard let refreshedIntent = self.acceptedTrackEndContinuationIntent(
                originalIntent: intent,
                occurrence: terminalOccurrence
            ) else { return }
            continuationIntent = refreshedIntent
            endedNavigationContext = self.playbackNavigationContext
            endedEntryID = self.queueEntryIDOwningCurrentPlayback
        }

        if let observedVideoId = self.normalizedPlaybackVideoId(observedVideoId) {
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
            await self.pause(intent: continuationIntent)
            return
        }
        self.shouldSuppressAutoplayAfterQueueEnd = false
        if self.repeatMode == .one {
            self.logger.info("Track ended with repeat one; replaying current queue song")
            await self.replayCurrentQueueSongForRepeatOneAfterTrackEnd(
                intent: continuationIntent,
                startsPaused: startsPaused
            )
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
        guard shouldContinue(),
              let refreshedIntent = self.acceptedTrackEndContinuationIntent(
                  originalIntent: intent,
                  occurrence: terminalOccurrence
              )
        else { return }
        continuationIntent = refreshedIntent
        let didAdvance = await self.performNextNavigation(
            intent: continuationIntent,
            startsPaused: startsPaused
        )
        guard shouldContinue(),
              let postNavigationIntent = self.acceptedTrackEndContinuationIntent(
                  originalIntent: intent,
                  occurrence: terminalOccurrence
              )
        else { return }
        continuationIntent = postNavigationIntent
        if !didAdvance {
            guard self.playbackNavigationContext == endedNavigationContext else { return }
            if await self.advanceToMaterializedNextQueueSongIfAvailable(
                after: endedEntryID,
                intent: continuationIntent,
                startsPaused: startsPaused
            ) {
                return
            }
            guard shouldContinue(),
                  self.acceptedTrackEndContinuationIntent(
                      originalIntent: intent,
                      occurrence: terminalOccurrence
                  ) != nil
            else { return }
            await self.finishPlaybackAfterFailedQueueAdvance(
                reason: "continuation produced no next queue entry"
            )
        }
    }

    // swiftlint:enable cyclomatic_complexity function_body_length

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

    // swiftlint:disable:next function_body_length
    func updateTrackMetadata(
        title: String,
        artist: String,
        thumbnailUrl: String,
        videoId observedVideoId: String?,
        playbackOccurrence: MusicPlaybackOccurrence?,
        allowsObservedArtistForMatchingVideo: Bool = false
    ) {
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
        let normalizedArtistName = Self.normalizedWebArtistName(artist)
        // The WebView byline can carry a view-count tail (e.g. "Artist • 1.3M views");
        // strip it so it never surfaces as the displayed artist name. The id stays
        // non-navigable ("unknown") because this is an unresolved placeholder — the
        // resolved, navigable identity arrives from `fetchSongMetadata`.
        let artistObj = Artist(id: "unknown", name: normalizedArtistName)
        let normalizedObservedVideoId = self.normalizedPlaybackVideoId(observedVideoId)
        let resolvedVideoId = self.resolvedObservedVideoId(observedVideoId)
        let videoIdChanged = normalizedObservedVideoId.map { self.currentTrack?.videoId != $0 } ?? false
        let trackChanged = if let normalizedObservedVideoId {
            self.currentTrack?.videoId != normalizedObservedVideoId
        } else {
            self.currentTrack?.title != title
                || self.currentTrack?.artistsDisplay != normalizedArtistName
        }

        if self.suppressUnexpectedAutoplayAfterQueueEndIfNeeded(
            trackChanged: trackChanged,
            observedVideoId: observedVideoId,
            title: title,
            artist: normalizedArtistName,
            thumbnailUrl: thumbnailUrl
        ) {
            return
        }

        if self.handleKasetInitiatedPlaybackMetadata(
            observedVideoId: observedVideoId,
            title: title,
            artist: normalizedArtistName,
            thumbnailUrl: thumbnailUrl,
            trackChanged: trackChanged
        ) {
            return
        }

        if self.handleNearEndTrackChangeIfNeeded(
            observedVideoId: observedVideoId,
            title: title,
            artist: normalizedArtistName,
            thumbnailUrl: thumbnailUrl,
            trackChanged: trackChanged,
            playbackOccurrence: playbackOccurrence
        ) {
            return
        }

        if self.handleUnexpectedQueueDriftIfNeeded(
            observedVideoId: observedVideoId,
            title: title,
            artist: normalizedArtistName,
            thumbnailUrl: thumbnailUrl,
            trackChanged: trackChanged
        ) {
            return
        }

        if self.finalRepeatOneSafetyNetIfNeeded(
            observedVideoId: observedVideoId,
            title: title,
            artist: normalizedArtistName,
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

        if self.updateCurrentTrackForMatchingVideoIfNeeded(
            normalizedObservedVideoId: normalizedObservedVideoId,
            title: title,
            artist: artistObj,
            thumbnailURL: thumbnailURL,
            allowsObservedArtist: allowsObservedArtistForMatchingVideo
        ) {
            return
        }

        // The WebView can resend the same track when only its volatile byline tail
        // changes. Keep the resolved metadata and status, but still accept a newly
        // available thumbnail from the DOM.
        guard trackChanged else {
            guard let currentTrack = self.currentTrack,
                  let thumbnailURL,
                  currentTrack.thumbnailURL != thumbnailURL
            else { return }
            self.currentTrack = currentTrack.replacingDisplayMetadata(
                title: currentTrack.title,
                artists: currentTrack.artists,
                thumbnailURL: thumbnailURL
            )
            return
        }

        self.currentTrack = Song(
            id: resolvedVideoId,
            title: title,
            artists: [artistObj],
            album: nil,
            duration: self.observedDuration(for: resolvedVideoId),
            thumbnailURL: thumbnailURL,
            videoId: resolvedVideoId
        )

        self.resetTrackStatus()
        // Immediately restore like status from SongLikeStatusManager cache
        if let cachedStatus = self.songLikeStatusManager.status(for: resolvedVideoId) {
            self.currentTrackLikeStatus = cachedStatus
        }

        if videoIdChanged {
            self.clearWebQueueInjectionState()
            // Re-sync the web queue since the playing video changed natively.
            self.syncWebQueue()
        }
    }

    private func updateCurrentTrackForMatchingVideoIfNeeded(
        normalizedObservedVideoId: String?,
        title: String,
        artist: Artist,
        thumbnailURL: URL?,
        allowsObservedArtist: Bool
    ) -> Bool {
        guard let currentTrack = self.currentTrack,
              let normalizedObservedVideoId,
              currentTrack.videoId == normalizedObservedVideoId
        else { return false }

        let hasResolvedArtists = currentTrack.artists.contains { !$0.isUnresolvedPlaceholder }
        let observedArtistIsEmpty = artist.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // WebView/player metadata remains the display-title source of truth; artist
        // identity resolves independently. Preserve navigable artists and ignore
        // transient empty observations without pinning generated parser placeholders.
        let resolvedTitle = Self.resolvedObservedTitle(current: currentTrack.title, observed: title)
        let shouldApplyObservedArtist = allowsObservedArtist
            && !observedArtistIsEmpty
            && artist.name != currentTrack.artistsDisplay
        self.currentTrack = currentTrack.replacingDisplayMetadata(
            title: resolvedTitle,
            artists: shouldApplyObservedArtist || (!hasResolvedArtists && !observedArtistIsEmpty)
                ? [artist]
                : currentTrack.artists,
            thumbnailURL: thumbnailURL ?? currentTrack.thumbnailURL
        )
        return true
    }

    private static func resolvedObservedTitle(current: String, observed: String) -> String {
        let observed = observed.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders = ["", "Loading..."]
        guard !placeholders.contains(observed) else { return current }
        return observed
    }

    /// Normalizes a WebView-reported byline into a clean artist name.
    ///
    /// The observer normally supplies the structured player author, which is
    /// locale-independent. As a DOM fallback, remove only an unambiguous trailing
    /// English view-count segment without discarding names such as "21 Savage".
    static func normalizedWebArtistName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = trimmed.split(separator: "•", omittingEmptySubsequences: false)
        guard segments.count > 1,
              let trailingSegment = segments.last?.trimmingCharacters(in: .whitespacesAndNewlines),
              trailingSegment.range(
                  of: #"^(?:no|\p{N}[\p{N}\p{P}\p{Zs}]*[kmbt]?)\s+views?$"#,
                  options: [.regularExpression, .caseInsensitive]
              ) != nil
        else { return trimmed }

        return segments.dropLast()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " • ")
    }
}
