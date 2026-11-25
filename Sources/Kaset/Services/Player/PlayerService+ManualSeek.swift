import Foundation

@MainActor
extension PlayerService {
    static let seekToEndThreshold: TimeInterval = 0.5

    func handleManualSeekToEnd(
        intent: MusicPlaybackIntent,
        startsPaused suppliedStartsPaused: Bool? = nil
    ) async {
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        let startsPaused = suppliedStartsPaused ?? self.isExplicitPauseIntentActive
        self.logger.info("Manual seek reached end of track; routing through track-ended path")
        self.clearRestoredPlaybackSessionState()
        self.progress = self.duration

        if !self.queue.isEmpty,
           self.repeatMode != .one,
           self.canAdvanceNativeQueueAfterTrackEnd
        {
            guard self.claimTerminalMusicPlaybackOccurrence(self.currentMusicPlaybackOccurrence) else { return }
            SingletonPlayerWebView.shared.seekAndPause(to: self.duration)
            self.clearWebQueueInjectionState()
            self.clearPendingNativeQueueAdvance()
            let previousNavigationContext = self.playbackNavigationContext
            let previousEntryID = self.currentQueueEntryID
            let didAdvance = await self.performNextNavigation(
                intent: intent,
                startsPaused: startsPaused
            )
            if !didAdvance,
               !Task.isCancelled,
               self.acceptsMusicPlaybackIntent(intent),
               self.playbackNavigationContext == previousNavigationContext
            {
                if await self.advanceToMaterializedNextQueueSongIfAvailable(
                    after: previousEntryID,
                    intent: intent,
                    startsPaused: startsPaused
                ) {
                    return
                }
                guard !Task.isCancelled,
                      self.acceptsMusicPlaybackIntent(intent),
                      self.playbackNavigationContext == previousNavigationContext
                else { return }
                await self.finishPlaybackAfterFailedQueueAdvance(
                    reason: "manual seek continuation produced no next queue entry"
                )
            }
            return
        }

        if self.shouldSynchronizeWebViewForTerminalManualSeekToEnd {
            SingletonPlayerWebView.shared.seekAndPause(to: self.duration)
        }

        await self.handleTrackEnded(
            observedVideoId: self.currentTrack?.videoId,
            startsPaused: startsPaused
        )
    }

    private var shouldSynchronizeWebViewForTerminalManualSeekToEnd: Bool {
        if self.queue.isEmpty {
            return !(self.repeatMode == .one && (self.currentTrack != nil || self.pendingPlayVideoId != nil))
        }

        return !self.canAdvanceNativeQueueAfterTrackEnd
    }
}
