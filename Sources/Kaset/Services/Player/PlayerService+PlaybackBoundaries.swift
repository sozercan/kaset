import Foundation

@MainActor
extension PlayerService {
    func clearPlaybackForGuestStartup() {
        self.hasResolvedStartupPlaybackOwnership = true
        self.logger.info("Clearing active playback state for guest startup")
        guard self.restoredPlaybackSessionOwnerScope == Self.playbackSessionScopeGuest else {
            self.preservesSavedSessionWhileDisabled = false
            self.suppressNextEmptyQueuePersistence = false
            self.clearSavedQueue()
            self.clearPlaybackForPrivacyBoundary(persistEmptyQueue: true)
            return
        }
        self.logger.info("Preserving restored guest-owned playback session")
    }

    func clearGuestPlaybackForAuthenticatedStartup() {
        self.hasResolvedStartupPlaybackOwnership = true
        guard self.restoredPlaybackSessionOwnerScope == Self.playbackSessionScopeGuest else { return }
        self.logger.info("Clearing guest-owned playback state for authenticated startup")
        self.preservesSavedSessionWhileDisabled = false
        self.suppressNextEmptyQueuePersistence = false
        self.clearSavedQueue()
        self.clearPlaybackForPrivacyBoundary(persistEmptyQueue: true)
    }

    func clearPlaybackForSignOut() {
        self.hasResolvedStartupPlaybackOwnership = true
        self.preservesSavedSessionWhileDisabled = false
        self.suppressNextEmptyQueuePersistence = false
        self.logger.info("Clearing playback state for sign-out")
        self.clearPlaybackForPrivacyBoundary(persistEmptyQueue: true)
    }

    func tearDownForExperienceChange() {
        self.logger.info("Tearing down music playback for experience mode change")
        if !self.queue.isEmpty || self.currentTrack != nil {
            self.saveQueueForPersistence(syncWebQueue: false)
        }
        self.preservesSavedSessionWhileDisabled = true
        self.clearPlaybackForPrivacyBoundary(persistEmptyQueue: false)
    }

    func resumeAfterExperienceChange() {
        guard self.preservesSavedSessionWhileDisabled else { return }
        self.preservesSavedSessionWhileDisabled = false
        if self.queue.isEmpty, self.currentTrack == nil {
            _ = self.restoreQueueFromPersistence()
        }
    }

    private func clearPlaybackForPrivacyBoundary(persistEmptyQueue: Bool) {
        self.accountSessionGeneration &+= 1
        self.songLikeStatusManager.invalidateSession()
        self.libraryMutationStates.removeAll()
        self.confirmedLibraryStateByKey.removeAll()
        self.invalidatePendingPlaybackRequests()
        self.cancelDeferredQueueWork()
        self.clearRestoredPlaybackSessionState()
        self.clearQueueNavigationRecovery()
        self.clearWebQueueInjectionState()
        self.clearPendingNativeQueueAdvance()
        SingletonPlayerWebView.shared.tearDown()
        self.state = .idle
        self.shouldResumeAfterInterruption = false
        self.isAwaitingPlaybackConfirmation = false
        self.isExplicitPauseIntentActive = true
        self.songNearingEnd = false
        self.isKasetInitiatedPlayback = false
        self.shouldSuppressAutoplayAfterQueueEnd = false
        self.currentEpisode = nil
        self.currentTrack = nil
        self.activePlaybackQueueEntryID = nil
        self.resetMusicPlaybackOccurrenceState()
        self.pendingPlayVideoId = nil
        self.progress = 0
        self.currentTimeMs = 0
        self.setPlaybackStateVideoId(nil)
        self.currentLyricsLineIndex = nil
        self.currentLyricsDisplayTimeMs = nil
        self.duration = 0
        self.showMiniPlayer = false
        self.isMiniPlayerVisible = false
        self.showLyrics = false
        self.showQueue = false
        self.showVideo = false
        self.currentTrackHasVideo = false
        self.mixContinuationToken = nil
        self.mixContinuationRequiresAuth = false
        self.queueOrderBeforeShuffle = nil
        self.clearQueueUndoRedoHistory()
        self.currentIndex = 0
        if !persistEmptyQueue {
            self.suppressNextEmptyQueuePersistence = true
        }
        self.setQueue([])
        self.resetTrackStatus()
        if persistEmptyQueue {
            self.saveQueueForPersistence()
        }
    }

    func stop() async {
        let intent = self.beginMusicPlaybackIntent()
        await self.stop(intent: intent)
    }

    func stop(
        intent: MusicPlaybackIntent,
        preservesQueueContext: Bool = false
    ) async {
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        if !preservesQueueContext {
            self.cancelDeferredQueueWork()
        }
        self.logger.debug("Stopping playback")
        self.isStoppingPlayback = true
        self.shouldResumeAfterInterruption = false
        self.isAwaitingPlaybackConfirmation = false
        self.isExplicitPauseIntentActive = true
        self.clearRestoredPlaybackSessionState()
        self.clearQueueNavigationRecovery()
        self.clearWebQueueInjectionState()
        self.clearPendingNativeQueueAdvance()
        self.state = .idle
        self.songNearingEnd = false
        self.isKasetInitiatedPlayback = false
        self.shouldSuppressAutoplayAfterQueueEnd = false
        self.currentEpisode = nil
        self.currentTrack = nil
        self.activePlaybackQueueEntryID = nil
        self.resetMusicPlaybackOccurrenceState()
        self.pendingPlayVideoId = nil
        self.progress = 0
        self.currentTimeMs = 0
        self.setPlaybackStateVideoId(nil)
        self.currentLyricsLineIndex = nil
        self.currentLyricsDisplayTimeMs = nil
        self.duration = 0
        self.resetAdPlaybackState()
        await SingletonPlayerWebView.shared.cancelPendingPlayback()
        guard self.acceptsMusicPlaybackIntent(intent) else {
            self.isStoppingPlayback = false
            return
        }
        self.state = .idle
        self.shouldResumeAfterInterruption = false
        self.isAwaitingPlaybackConfirmation = false
        self.isExplicitPauseIntentActive = true
        self.currentTrack = nil
        self.activePlaybackQueueEntryID = nil
        self.pendingPlayVideoId = nil
        self.progress = 0
        self.currentTimeMs = 0
        self.duration = 0
        self.isStoppingPlayback = false
    }

    func stopAndClearQueue() async {
        let intent = self.beginMusicPlaybackIntent()
        await self.stopAndClearQueue(intent: intent)
    }

    func stopAndClearQueue(intent: MusicPlaybackIntent) async {
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        let undoState = self.makeQueueStateSnapshot()
        await self.stop(intent: intent)
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        self.clearQueueEntriesAfterStop(intent: intent, undoState: undoState)
    }
}
