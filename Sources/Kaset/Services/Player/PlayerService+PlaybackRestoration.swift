import Foundation

@MainActor
extension PlayerService {
    func updateAdPlaybackState(
        isShowingAd: Bool,
        observedProgress: TimeInterval,
        observedVideoId: String?,
        isAuthoritativeContent: Bool,
        now: ContinuousClock.Instant = .now
    ) {
        if isShowingAd {
            self.isShowingAd = true
            if observedProgress.isFinite, observedProgress >= 0 {
                if let previousProgress = self.lastAdPlaybackProgress,
                   observedProgress > previousProgress
                {
                    self.lastAdPlaybackProgressAt = now
                }
                self.lastAdPlaybackProgress = observedProgress
            }
            return
        }
        guard isAuthoritativeContent else { return }
        self.clearAdPlaybackBoundary()
        guard let observedVideoId = self.normalizedPlaybackVideoId(observedVideoId) else { return }
        self.lastNonAdContentProgress = observedProgress
        self.lastNonAdContentVideoId = observedVideoId
    }

    func clearAdPlaybackBoundary() {
        self.isShowingAd = false
    }

    func resetAdPlaybackState() {
        self.isShowingAd = false
        self.lastNonAdContentProgress = 0
        self.lastNonAdContentVideoId = nil
    }

    func lastNonAdContentProgress(for videoId: String) -> TimeInterval {
        self.lastNonAdContentVideoId == videoId ? self.lastNonAdContentProgress : 0
    }

    func pendingRestoredSeekForWebRecovery(videoId: String) -> TimeInterval? {
        guard self.pendingPlayVideoId == videoId,
              self.isRestoringPlaybackSession || self.isPendingRestoredLoadDeferred
        else { return nil }
        return self.pendingRestoredSeek
    }

    var shouldAutoplayPlaybackDocument: Bool {
        guard !self.isRestoringPlaybackSession,
              !self.isPendingRestoredLoadDeferred
        else { return false }
        return self.shouldResumeAfterInterruption
    }

    var shouldResumeReadyAdDuringRestoration: Bool {
        self.isRestoringPlaybackSession && self.shouldAutoResumeAfterRestoredLoad
    }

    func updatePlaybackState(isPlaying: Bool, progress: Double, duration: Double) {
        self.updatePlaybackState(
            isPlaying: isPlaying,
            progress: progress,
            duration: duration,
            observedVideoId: self.currentTrack?.videoId ?? self.pendingPlayVideoId
        )
    }

    func updatePlaybackState(
        isPlaying: Bool,
        progress: Double,
        duration: Double,
        observedVideoId: String?
    ) {
        self.recordPlaybackStateObservation(videoId: observedVideoId)
        guard self.observedPlaybackMatchesCurrentTarget(videoId: observedVideoId) else {
            self.logger.debug(
                "Ignoring playback state for stale video \(observedVideoId ?? "unknown")"
            )
            return
        }

        self.applyPlaybackStateObservation(
            isPlaying: isPlaying,
            progress: progress,
            duration: duration
        )
        self.recordDurationObservation(
            videoId: self.playbackStateVideoId,
            duration: duration
        )
    }

    private func applyPlaybackStateObservation(
        isPlaying: Bool,
        progress: Double,
        duration: Double
    ) {
        let previousProgress = self.progress
        self.isApplyingPlaybackStateObservation = true
        defer {
            self.isApplyingPlaybackStateObservation = false
        }

        if self.isPendingRestoredLoadDeferred {
            if self.pendingRestoredSeek == nil {
                self.progress = progress
            }
            if duration > 0 {
                self.duration = duration
            }
            self.state = .paused
            if isPlaying, !self.hasIssuedAutoplayPauseDuringDeferredRestore {
                self.hasIssuedAutoplayPauseDuringDeferredRestore = true
                SingletonPlayerWebView.shared.pause()
            }
            if let targetProgress = self.pendingRestoredSeek {
                _ = self.scheduleTerminalRestoredSeekIfNeeded(
                    targetProgress: targetProgress,
                    resolvedDuration: self.duration
                )
            }
            return
        }

        if self.isRestoringPlaybackSession {
            self.reconcileRestoredPlaybackState(
                isPlaying: isPlaying,
                progress: progress,
                duration: duration,
                previousProgress: previousProgress
            )
        } else {
            self.applyObservedPlaybackState(
                isPlaying: isPlaying,
                progress: progress,
                duration: duration,
                previousProgress: previousProgress
            )
        }
    }

    func updatePlaybackTransportState(isPlaying: Bool) {
        if isPlaying {
            guard self.shouldResumeAfterInterruption
                || self.shouldResumeReadyAdDuringRestoration
            else { return }
            switch self.state {
            case .loading, .paused, .playing, .buffering:
                self.state = .playing
            case .idle, .ended, .error:
                break
            }
        } else {
            self.isAwaitingPlaybackConfirmation = false
            switch self.state {
            case .loading, .playing, .buffering:
                self.state = .paused
            case .idle, .paused, .ended, .error:
                break
            }
        }
    }

    func applyRestoredPlaybackSession(
        queue: [Song],
        entrySources: [QueueEntry.Source]? = nil,
        currentIndex: Int,
        progress: TimeInterval,
        duration: TimeInterval
    ) {
        guard let currentSong = queue[safe: currentIndex] else { return }
        self.beginMusicPlaybackIntent()
        self.playbackContextGeneration &+= 1
        self.clearQueueNavigationRecovery()
        self.clearWebQueueInjectionState()
        self.clearPendingNativeQueueAdvance()
        self.cancelDeferredQueueWork()
        self.clearQueueUndoRedoHistory()

        self.clearRestoredPlaybackSessionState()
        self.restoredPlaybackSessionGeneration &+= 1
        let restoreGeneration = self.restoredPlaybackSessionGeneration
        self.clearForwardSkipNavigationStack()
        if let entrySources, entrySources.count == queue.count {
            self.setQueue(entries: zip(queue, entrySources).map { song, source in
                QueueEntry(id: UUID(), song: song, source: source)
            })
        } else {
            self.setQueue(queue)
        }
        self.currentIndex = currentIndex
        self.activePlaybackQueueEntryID = self.currentQueueEntryID
        self.currentTrack = currentSong
        self.pendingPlayVideoId = currentSong.videoId
        self.currentTrackHasVideo = currentSong.musicVideoType?.hasVideoContent ?? currentSong.hasVideo ?? false
        self.showMiniPlayer = false
        self.songNearingEnd = false
        self.isKasetInitiatedPlayback = false
        self.isAwaitingWebRestoredTrack = true
        self.hasIssuedAutoplayPauseDuringDeferredRestore = false

        let resolvedDuration = max(duration, currentSong.duration ?? 0)
        let clampedProgress = self.clampedRestoredProgress(progress, duration: resolvedDuration)

        self.progress = clampedProgress
        self.duration = resolvedDuration
        self.recordDurationObservation(videoId: currentSong.videoId, duration: resolvedDuration)
        self.state = .paused
        self.pendingRestoredSeek = clampedProgress
        self.isPendingRestoredLoadDeferred = true

        if let tokens = currentSong.feedbackTokens {
            self.currentTrackFeedbackTokens = tokens
            self.currentTrackInLibrary = currentSong.isInLibrary ?? false
            self.currentTrackLikeStatus = currentSong.likeStatus ?? .indifferent
        } else {
            self.resetTrackStatus()
        }

        if let persistedLikeStatus = currentSong.likeStatus, persistedLikeStatus != .indifferent {
            self.songLikeStatusManager.setStatus(persistedLikeStatus, for: currentSong.videoId)
            self.currentTrackLikeStatus = persistedLikeStatus
        }

        if let cachedStatus = self.songLikeStatusManager.status(for: currentSong.videoId) {
            self.currentTrackLikeStatus = cachedStatus
        }

        let queueEntryID = self.currentQueueEntryID
        Task { [videoId = currentSong.videoId] in
            await self.fetchSongMetadata(
                videoId: videoId,
                queueOwner: queueEntryID.map(MusicQueueMetadataOwner.entry) ?? .none
            )
        }

        Task {
            try? await Task.sleep(for: .seconds(8))
            guard self.restoredPlaybackSessionGeneration == restoreGeneration,
                  self.isPendingRestoredLoadDeferred,
                  self.isAwaitingWebRestoredTrack
            else { return }
            self.logger.info("No server-restored track observed; falling back to persisted session track")
            self.pendingPlayVideoId = currentSong.videoId
            self.currentTrack = currentSong
            self.currentTrackHasVideo = currentSong.musicVideoType?.hasVideoContent ?? currentSong.hasVideo ?? false
            self.isAwaitingWebRestoredTrack = false
        }
    }

    func clearRestoredPlaybackSessionState() {
        self.pendingRestoredSeek = nil
        self.isPendingRestoredLoadDeferred = false
        self.shouldForcePendingRestoredLoad = false
        self.isRestoringExplicitTransportSeek = false
        self.shouldFinishRestoredSeekAtEnd = false
        self.restoredPlaybackSessionGeneration &+= 1
        self.isRestoringPlaybackSession = false
        self.shouldAutoResumeAfterRestoredLoad = false
        self.isAwaitingWebRestoredTrack = false
    }

    @discardableResult
    func beginPlaybackClockRestoration(
        _ restoreClock: MusicPlaybackRestoreClock,
        songDuration: TimeInterval?,
        startsPaused: Bool
    ) -> TimeInterval {
        self.clearRestoredPlaybackSessionState()
        self.isRestoringExplicitTransportSeek = restoreClock.isExplicitTransportSeek
        self.shouldFinishRestoredSeekAtEnd = restoreClock.isExplicitTransportSeek
        let resolvedDuration: TimeInterval = if restoreClock.duration > 0 {
            restoreClock.duration
        } else if restoreClock.allowsSongDurationFallback {
            songDuration ?? 0
        } else {
            0
        }
        let targetProgress = self.clampedRestoredProgress(
            restoreClock.progress,
            duration: resolvedDuration
        )
        self.progress = targetProgress
        self.currentTimeMs = Int(targetProgress * 1000)
        self.duration = resolvedDuration
        self.recordDurationObservation(videoId: self.currentTrack?.videoId, duration: resolvedDuration)
        self.pendingRestoredSeek = targetProgress
        self.isRestoringPlaybackSession = true
        self.shouldAutoResumeAfterRestoredLoad = !startsPaused
        self.shouldResumeAfterInterruption = !startsPaused
        self.isAwaitingPlaybackConfirmation = !startsPaused
        self.isExplicitPauseIntentActive = startsPaused
        self.unattributedRemotePauseAt = nil
        self.state = startsPaused ? .paused : .loading
        return targetProgress
    }

    func retargetRestoredPlaybackSeekIfNeeded(
        to targetProgress: TimeInterval,
        intent: MusicPlaybackIntent
    ) async -> Bool {
        let isDeferredRestore = self.isPendingRestoredLoadDeferred
        let isActiveRestore = self.isRestoringPlaybackSession && self.pendingRestoredSeek != nil
        guard isDeferredRestore || isActiveRestore else { return false }

        let startsPaused = isDeferredRestore
            || self.isExplicitPauseIntentActive
            || !self.shouldAutoResumeAfterRestoredLoad
        if self.duration > 0,
           targetProgress >= self.duration - Self.seekToEndThreshold
        {
            await self.handleManualSeekToEnd(
                intent: intent,
                startsPaused: startsPaused
            )
            return true
        }

        self.progress = targetProgress
        self.currentTimeMs = Int(targetProgress * 1000)
        self.pendingRestoredSeek = targetProgress
        self.isRestoringExplicitTransportSeek = true
        self.shouldFinishRestoredSeekAtEnd = true
        return true
    }

    func beginRestoredPlaybackLoad(autoResumeAfterSeek: Bool) {
        self.isPendingRestoredLoadDeferred = false
        self.isRestoringPlaybackSession = true
        self.shouldAutoResumeAfterRestoredLoad = autoResumeAfterSeek

        if autoResumeAfterSeek {
            self.state = .loading
        }
    }

    func deferRestoredPlaybackAfterNavigationFailure() {
        if self.pendingPlayVideoId == nil {
            self.pendingPlayVideoId = self.currentTrack?.videoId
        }

        if self.pendingRestoredSeek == nil, self.state != .ended {
            let contentProgress: TimeInterval = if self.isShowingAd,
                                                   let targetVideoId = self.pendingPlayVideoId
            {
                self.lastNonAdContentProgress(for: targetVideoId)
            } else {
                self.progress
            }
            self.pendingRestoredSeek = contentProgress > 0 ? contentProgress : nil
        }
        self.isRestoringPlaybackSession = false
        self.isPendingRestoredLoadDeferred = true
        self.shouldForcePendingRestoredLoad = true
        self.shouldAutoResumeAfterRestoredLoad = false
        self.shouldResumeAfterInterruption = false

        if self.state != .ended {
            self.state = .paused
        }
    }

    var shouldLoadPendingVideoBeforePlayback: Bool {
        guard let pendingPlayVideoId = self.pendingPlayVideoId else { return false }
        return self.shouldForcePendingRestoredLoad || self.currentWebPlaybackVideoId() != pendingPlayVideoId
    }

    func reloadCurrentTrackForAuthDataStoreChange(usesCookieFreeDataStore: Bool) {
        guard self.currentTrack != nil else { return }
        let isDeferredGuestRestore = self.restoredPlaybackSessionOwnerScope == Self.playbackSessionScopeGuest
            && self.isPendingRestoredLoadDeferred
        if usesCookieFreeDataStore || !isDeferredGuestRestore {
            self.updateRestoredPlaybackSessionOwnerScope(
                usesCookieFreeDataStore ? Self.playbackSessionScopeGuest : Self.playbackSessionScopeAuthenticated
            )
        }
        SingletonPlayerWebView.shared.rebuildForAuthDataStoreChange(usesCookieFreeDataStore: usesCookieFreeDataStore)
        self.reloadCurrentTrackForIdentitySwitch()
    }

    private func clearAccountScopedPlaybackMetadata() {
        func sanitized(_ entry: QueueEntry) -> QueueEntry {
            var song = entry.song
            song.likeStatus = nil
            song.isInLibrary = nil
            song.feedbackTokens = nil
            return QueueEntry(id: entry.id, song: song, source: entry.source)
        }

        self.setQueue(entries: self.queueEntries.map(sanitized))
        self.queueOrderBeforeShuffle = self.queueOrderBeforeShuffle?.map(sanitized)
        if var currentTrack = self.currentTrack {
            currentTrack.likeStatus = nil
            currentTrack.isInLibrary = nil
            currentTrack.feedbackTokens = nil
            self.currentTrack = currentTrack
        }
        self.resetTrackStatus()
        self.saveQueueForPersistence(
            ownerScopeOverride: self.restoredPlaybackSessionOwnerScope
        )
    }

    func reloadCurrentTrackForIdentitySwitch(invalidatesLikeSession: Bool = true) {
        self.accountSessionGeneration &+= 1
        if invalidatesLikeSession {
            self.songLikeStatusManager.invalidateSession(clearsActiveCache: false)
        }
        self.beginMusicPlaybackIntent()
        self.playbackContextGeneration &+= 1
        self.clearQueueNavigationRecovery()
        self.clearWebQueueInjectionState()
        self.clearPendingNativeQueueAdvance()
        self.cancelDeferredQueueWork()
        self.clearQueueUndoRedoHistory()
        self.libraryMutationStates.removeAll()
        self.confirmedLibraryStateByKey.removeAll()
        self.mixContinuationToken = nil
        self.mixContinuationRequiresAuth = false
        self.clearAccountScopedPlaybackMetadata()

        guard let currentTrack = self.currentTrack else {
            self.logger.debug("Identity switch: no current track to re-point")
            return
        }

        if self.isPendingRestoredLoadDeferred {
            self.logger.debug("Identity switch: restored session still deferred; skipping re-point")
            return
        }
        if self.currentWebPlaybackVideoId() != currentTrack.videoId {
            self.logger.debug("Identity switch: current track not loaded in WebView; skipping re-point")
            return
        }

        let resumeProgress = self.state == .ended ? 0 : self.progress
        let wasPlaying = self.isPlaying
        let shouldAutoResumeAfterReload = wasPlaying || self.state == .loading
        self.logger.info("Identity switch: re-pointing current track under new session identity (resume at \(Int(resumeProgress))s, wasPlaying=\(wasPlaying))")

        self.pendingRestoredSeek = self.state == .ended ? nil : resumeProgress
        if !shouldAutoResumeAfterReload {
            self.pendingPlayVideoId = currentTrack.videoId
            self.isPendingRestoredLoadDeferred = true
            self.shouldForcePendingRestoredLoad = true
            if self.state != .ended {
                self.state = .paused
            }
            return
        }
        self.beginRestoredPlaybackLoad(autoResumeAfterSeek: shouldAutoResumeAfterReload)

        SingletonPlayerWebView.shared.loadVideo(
            videoId: currentTrack.videoId,
            strategy: .forceFullPageWhenSameVideoId
        )
    }
}

private extension PlayerService {
    func applyObservedPlaybackState(
        isPlaying: Bool,
        progress: Double,
        duration: Double,
        previousProgress: TimeInterval
    ) {
        if self.progress != progress {
            self.progress = progress
        }
        if self.duration != duration {
            self.duration = duration
        }

        if isPlaying {
            guard !self.isExplicitPauseIntentActive else {
                SingletonPlayerWebView.shared.pause()
                return
            }
            self.isAwaitingPlaybackConfirmation = false
            self.confirmPlaybackStarted()
        } else {
            self.isAwaitingPlaybackConfirmation = false
            switch self.state {
            case .loading, .playing, .buffering:
                self.state = .paused
            case .idle, .paused, .ended, .error:
                break
            }
        }

        if duration > 0, progress >= duration - 2, previousProgress < duration - 2 {
            self.songNearingEnd = true
        }
    }

    func reconcileRestoredPlaybackState(
        isPlaying: Bool,
        progress: Double,
        duration: Double,
        previousProgress: TimeInterval
    ) {
        let resolvedDuration = self.resolveRestoredDuration(from: duration)

        if let targetProgress = self.pendingRestoredSeek {
            self.reconcilePendingRestoredSeek(
                isPlaying: isPlaying,
                progress: progress,
                targetProgress: targetProgress,
                resolvedDuration: resolvedDuration
            )
            return
        }

        let resolvedProgress = progress > 0 ? progress : previousProgress
        if self.progress != resolvedProgress {
            self.progress = resolvedProgress
        }
        self.reconcileRestoredPlaybackWithoutPendingSeek(
            isPlaying: isPlaying,
            resolvedDuration: resolvedDuration
        )
    }

    func resolveRestoredDuration(from duration: Double) -> TimeInterval {
        let resolvedDuration = duration > 0 ? duration : self.duration
        if self.duration != resolvedDuration {
            self.duration = resolvedDuration
        }
        return resolvedDuration
    }

    @discardableResult
    func scheduleTerminalRestoredSeekIfNeeded(
        targetProgress: TimeInterval,
        resolvedDuration: TimeInterval
    ) -> Bool {
        let clampedTargetProgress = self.clampedRestoredProgress(
            targetProgress,
            duration: resolvedDuration
        )
        guard self.shouldFinishRestoredSeekAtEnd,
              resolvedDuration > 0,
              clampedTargetProgress >= resolvedDuration - Self.seekToEndThreshold
        else { return false }

        let intent = self.currentMusicPlaybackIntent
        let restorationGeneration = self.restoredPlaybackSessionGeneration
        let playbackVideoId = self.currentTrack?.videoId ?? self.pendingPlayVideoId
        let queueEntryID = self.queueEntryIDOwningCurrentPlayback
        let startsPaused = self.isPendingRestoredLoadDeferred
            || self.isExplicitPauseIntentActive
            || !self.shouldAutoResumeAfterRestoredLoad
        Task { @MainActor [weak self] in
            guard let self,
                  self.acceptsMusicPlaybackIntent(intent),
                  self.restoredPlaybackSessionGeneration == restorationGeneration,
                  self.isRestoringPlaybackSession || self.isPendingRestoredLoadDeferred,
                  self.isRestoringExplicitTransportSeek,
                  self.shouldFinishRestoredSeekAtEnd,
                  self.pendingRestoredSeek == targetProgress,
                  (self.currentTrack?.videoId ?? self.pendingPlayVideoId) == playbackVideoId,
                  self.queueEntryIDOwningCurrentPlayback == queueEntryID,
                  self.duration > 0,
                  self.clampedRestoredProgress(
                      targetProgress,
                      duration: self.duration
                  ) >= self.duration - Self.seekToEndThreshold
            else { return }
            self.shouldFinishRestoredSeekAtEnd = false
            await self.handleManualSeekToEnd(
                intent: intent,
                startsPaused: startsPaused
            )
        }
        return true
    }

    func reconcilePendingRestoredSeek(
        isPlaying: Bool,
        progress: Double,
        targetProgress: TimeInterval,
        resolvedDuration: TimeInterval
    ) {
        if self.scheduleTerminalRestoredSeekIfNeeded(
            targetProgress: targetProgress,
            resolvedDuration: resolvedDuration
        ) {
            return
        }
        let clampedTargetProgress = self.clampedRestoredProgress(targetProgress, duration: resolvedDuration)
        if self.progress != clampedTargetProgress {
            self.progress = clampedTargetProgress
        }

        guard resolvedDuration > 0 || clampedTargetProgress == 0 else {
            self.state = self.shouldAutoResumeAfterRestoredLoad ? .loading : .paused
            return
        }

        let isAtRestoredPosition = self.isAtRestoredPosition(
            observedProgress: progress,
            targetProgress: clampedTargetProgress
        )

        if !isAtRestoredPosition, resolvedDuration > 0 {
            SingletonPlayerWebView.shared.seek(to: clampedTargetProgress)
        }

        if self.shouldAutoResumeAfterRestoredLoad {
            self.finishRestoredAutoResumeLoad(
                isPlaying: isPlaying,
                observedProgress: progress,
                targetProgress: clampedTargetProgress,
                isAtRestoredPosition: isAtRestoredPosition
            )
            return
        }

        self.finishRestoredPausedLoad(
            isPlaying: isPlaying,
            observedProgress: progress,
            targetProgress: clampedTargetProgress,
            isAtRestoredPosition: isAtRestoredPosition
        )
    }

    func finishRestoredAutoResumeLoad(
        isPlaying: Bool,
        observedProgress: Double,
        targetProgress: TimeInterval,
        isAtRestoredPosition: Bool
    ) {
        self.state = .loading

        guard isAtRestoredPosition || targetProgress == 0 else {
            if isPlaying {
                SingletonPlayerWebView.shared.pause()
            }
            return
        }

        self.progress = isAtRestoredPosition ? observedProgress : targetProgress

        let shouldIssuePlay = !isPlaying
        self.clearRestoredPlaybackSessionState()

        if shouldIssuePlay {
            SingletonPlayerWebView.shared.play()
        } else {
            self.state = .playing
        }
    }

    func finishRestoredPausedLoad(
        isPlaying: Bool,
        observedProgress: Double,
        targetProgress: TimeInterval,
        isAtRestoredPosition: Bool
    ) {
        self.state = .paused

        if isPlaying {
            SingletonPlayerWebView.shared.pause()
        }

        guard !isPlaying, isAtRestoredPosition || targetProgress == 0 else { return }

        self.progress = isAtRestoredPosition ? observedProgress : targetProgress
        self.clearRestoredPlaybackSessionState()
    }

    func reconcileRestoredPlaybackWithoutPendingSeek(
        isPlaying: Bool,
        resolvedDuration: TimeInterval
    ) {
        if self.shouldAutoResumeAfterRestoredLoad {
            self.state = .loading

            if isPlaying {
                self.clearRestoredPlaybackSessionState()
                self.state = .playing
            } else if resolvedDuration > 0 {
                self.clearRestoredPlaybackSessionState()
                SingletonPlayerWebView.shared.play()
            }
            return
        }

        self.state = .paused

        if !isPlaying, resolvedDuration > 0 {
            self.clearRestoredPlaybackSessionState()
        }
    }

    func clampedRestoredProgress(_ progress: TimeInterval, duration: TimeInterval) -> TimeInterval {
        if duration > 0 {
            return min(max(progress, 0), duration)
        }
        return max(progress, 0)
    }

    func isAtRestoredPosition(
        observedProgress: Double,
        targetProgress: TimeInterval
    ) -> Bool {
        let tolerance: TimeInterval = 1.5
        return abs(observedProgress - targetProgress) <= tolerance
    }
}
