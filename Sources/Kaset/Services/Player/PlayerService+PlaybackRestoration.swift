import Foundation

// MARK: - Playback Restoration

@MainActor
extension PlayerService {
    /// Updates playback state from the persistent WebView observer.
    func updatePlaybackState(isPlaying: Bool, progress: Double, duration: Double) {
        let previousProgress = self.progress

        guard !self.isRestoringPlaybackSession else {
            self.reconcileRestoredPlaybackState(
                isPlaying: isPlaying,
                progress: progress,
                duration: duration,
                previousProgress: previousProgress
            )
            return
        }

        self.applyObservedPlaybackState(
            isPlaying: isPlaying,
            progress: progress,
            duration: duration,
            previousProgress: previousProgress
        )
    }

    /// Applies a previously persisted playback session in a paused, resume-ready state.
    func applyRestoredPlaybackSession(
        queue: [Song],
        currentIndex: Int,
        progress: TimeInterval,
        duration: TimeInterval
    ) {
        guard let currentSong = queue[safe: currentIndex] else { return }

        self.clearRestoredPlaybackSessionState()
        self.clearForwardSkipNavigationStack()
        self.setQueue(queue)
        self.currentIndex = currentIndex
        self.currentTrack = currentSong
        self.pendingPlayVideoId = currentSong.videoId
        self.currentTrackHasVideo = currentSong.musicVideoType?.hasVideoContent ?? currentSong.hasVideo ?? false
        self.showMiniPlayer = false
        self.songNearingEnd = false
        self.isKasetInitiatedPlayback = false

        let resolvedDuration = max(duration, currentSong.duration ?? 0)
        let clampedProgress = self.clampedRestoredProgress(progress, duration: resolvedDuration)

        self.progress = clampedProgress
        self.duration = resolvedDuration
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

        // Seed the SongLikeStatusManager cache from the persisted song's likeStatus
        // so that fetchSongMetadata won't overwrite it with a parsed .indifferent default.
        if let persistedLikeStatus = currentSong.likeStatus, persistedLikeStatus != .indifferent {
            SongLikeStatusManager.shared.setStatus(persistedLikeStatus, for: currentSong.videoId)
            self.currentTrackLikeStatus = persistedLikeStatus
        }

        // SongLikeStatusManager cache is the most up-to-date source for like status
        if let cachedStatus = SongLikeStatusManager.shared.status(for: currentSong.videoId) {
            self.currentTrackLikeStatus = cachedStatus
        }

        // At app launch the cache may be empty and the persisted song may lack likeStatus.
        // Fetch metadata from the API to get the correct like status.
        Task { [videoId = currentSong.videoId] in
            await self.fetchSongMetadata(videoId: videoId)
        }
    }

    /// Clears one-shot state used while reconciling a restored playback session.
    func clearRestoredPlaybackSessionState() {
        self.pendingRestoredSeek = nil
        self.isPendingRestoredLoadDeferred = false
        self.shouldForcePendingRestoredLoad = false
        self.isRestoringPlaybackSession = false
        self.shouldAutoResumeAfterRestoredLoad = false
    }

    /// Starts loading a restored session into the WebView without discarding the saved seek target.
    func beginRestoredPlaybackLoad(autoResumeAfterSeek: Bool) {
        self.isPendingRestoredLoadDeferred = false
        self.isRestoringPlaybackSession = true
        self.shouldAutoResumeAfterRestoredLoad = autoResumeAfterSeek

        if autoResumeAfterSeek {
            self.state = .loading
        }
    }

    /// Whether the pending track must be loaded into the WebView before playback can resume.
    var shouldLoadPendingVideoBeforePlayback: Bool {
        guard let pendingPlayVideoId = self.pendingPlayVideoId else { return false }
        return self.shouldForcePendingRestoredLoad || SingletonPlayerWebView.shared.currentVideoId != pendingPlayVideoId
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

    /// Re-loads the currently playing track so it is served under the WebView
    /// session's current (just-switched) delegated identity.
    ///
    /// History is recorded by the playback page's own stats pings, which inherit
    /// the identity of the document that was loaded. After an account switch the
    /// in-flight page is still the previous identity's document, so a full-page
    /// reload is required for subsequent listening to record to the new account.
    /// Playback position and play/pause intent are preserved across the reload
    /// via the existing restored-session machinery.
    func reloadCurrentTrackForIdentitySwitch() {
        guard let currentTrack = self.currentTrack else {
            self.logger.debug("Identity switch: no current track to re-point")
            return
        }

        // Skip if a restored session is still deferred (cold launch, paused, not
        // yet loaded into the WebView). There is no previous-identity document to
        // re-point, and force-navigating here would clear the explicit-resume gate
        // and load the playback page (and its history stats) before the user
        // chooses to resume. The eventual user-initiated load already uses the
        // now-verified session identity.
        if self.isPendingRestoredLoadDeferred {
            self.logger.debug("Identity switch: restored session still deferred; skipping re-point")
            return
        }
        // If the current track was never actually loaded into the WebView, there
        // is likewise nothing to re-point under the old identity.
        if SingletonPlayerWebView.shared.currentVideoId != currentTrack.videoId {
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

        // Force a full navigation even though the videoId is unchanged: the
        // identity lives in the served document, so an in-place restart would
        // keep recording to the previous account.
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
            self.confirmPlaybackStarted()
        } else if self.state == .playing {
            self.state = .paused
        }

        // Detect when song is about to end (within last 2 seconds)
        // This helps us prepare to play the next track from our queue.
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

    func reconcilePendingRestoredSeek(
        isPlaying: Bool,
        progress: Double,
        targetProgress: TimeInterval,
        resolvedDuration: TimeInterval
    ) {
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
