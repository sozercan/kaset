import Foundation

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
        self.clearRestoredPlaybackSessionState()
        self.progress = self.duration

        if !self.queue.isEmpty,
           self.repeatMode != .one,
           self.canAdvanceNativeQueueAfterTrackEnd
        {
            SingletonPlayerWebView.shared.seekAndPause(to: self.duration)
            self.clearWebQueueInjectionState()
            self.clearPendingNativeQueueAdvance()
            let previousEntryID = self.currentQueueEntryID
            let previousIndex = self.currentIndex
            let didAdvance = await self.performNextNavigation()
            if !didAdvance,
               !Task.isCancelled,
               self.currentQueueEntryID == previousEntryID,
               self.currentIndex == previousIndex
            {
                await self.finishPlaybackAfterFailedQueueAdvance(
                    reason: "manual seek continuation produced no next queue entry"
                )
            }
            return
        }

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
}
