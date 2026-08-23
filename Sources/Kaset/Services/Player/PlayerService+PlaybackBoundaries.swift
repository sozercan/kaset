import Foundation

@MainActor
extension PlayerService {
    /// Clears active playback UI/WebView state when startup resolves to guest mode.
    ///
    /// Unlike explicit sign-out, this preserves only persisted sessions that are
    /// known to have been created in guest mode. Legacy/unknown sessions are
    /// cleared because they may contain account-owned listening metadata.
    func clearPlaybackForGuestStartup() {
        self.logger.info("Clearing active playback state for guest startup")
        guard self.restoredPlaybackSessionOwnerScope == Self.playbackSessionScopeGuest else {
            self.clearSavedQueue()
            self.clearPlaybackForPrivacyBoundary(persistEmptyQueue: true)
            return
        }
        self.logger.info("Preserving restored guest-owned playback session")
    }

    /// Clears guest-owned restored playback when startup resolves to a signed-in
    /// account. Guest Mode itself is not persisted, so a guest-owned restore must
    /// not silently move onto the authenticated playback store.
    func clearGuestPlaybackForAuthenticatedStartup() {
        guard self.restoredPlaybackSessionOwnerScope == Self.playbackSessionScopeGuest else { return }
        self.logger.info("Clearing guest-owned playback state for authenticated startup")
        self.clearSavedQueue()
        self.clearPlaybackForPrivacyBoundary(persistEmptyQueue: true)
    }

    /// Synchronously clears playback, queue, and WebView state at the sign-out privacy boundary.
    func clearPlaybackForSignOut() {
        self.logger.info("Clearing playback state for sign-out")
        self.clearPlaybackForPrivacyBoundary(persistEmptyQueue: true)
    }

    private func clearPlaybackForPrivacyBoundary(persistEmptyQueue: Bool) {
        self.accountSessionGeneration &+= 1
        self.songLikeStatusManager.invalidateSession()
        self.confirmedLibraryStateByKey.removeAll()
        self.invalidatePendingPlaybackRequests()
        self.cancelDeferredQueueWork()
        self.clearRestoredPlaybackSessionState()
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

    /// Stops playback and clears state.
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

    /// Stops current or pending playback and clears the queue under one intent.
    /// A newer playback that starts while Web cancellation suspends wins.
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
