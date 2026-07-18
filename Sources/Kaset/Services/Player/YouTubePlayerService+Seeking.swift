import Foundation

@MainActor
extension YouTubePlayerService {
    /// Distance from the known duration at which a manual seek is treated as a
    /// completed watch. Seeking a WebKit video element to exactly `duration`
    /// does not reliably emit `ended`, so terminal seeks must not depend on the
    /// page's natural ended event to refresh Continue Watching state.
    private static let seekToEndThreshold: TimeInterval = 0.5

    /// Window during which repeated relative-seek button presses should build
    /// from the last requested target instead of the last observer-reported
    /// progress. YouTube's `STATE_UPDATE` observer is coarse and can briefly
    /// report pre-seek progress after a button press.
    private static let relativeSeekTargetCoalescingWindow: Duration = .seconds(1)

    /// Seeks to a position in seconds.
    func seek(to time: Double) {
        self.beginYouTubePlaybackIntent()
        self.clearRelativeSeekCoalescingTarget()
        self.performSeek(to: time)
    }

    func handleRemoteSeek(
        to time: Double,
        issuedAtMilliseconds: Double
    ) {
        guard self.admitYouTubeRemoteCommand(
            issuedAtMilliseconds: issuedAtMilliseconds
        ) else { return }
        self.clearRelativeSeekCoalescingTarget()
        self.performSeek(to: time)
    }

    private func performSeek(to time: Double) {
        guard time.isFinite else { return }
        self.invalidateExplicitStartTargetForUserSeek()
        let target = self.clampedSeekTarget(time)
        if self.duration > 0, target >= self.duration - Self.seekToEndThreshold {
            self.handleManualSeekToEnd()
            return
        }

        self.recordPendingUserSeek(to: target)
        self.progress = target
        if self.pendingPausedIdentityReloadVideoId == self.currentVideo?.videoId {
            self.pendingPausedIdentityReloadResumeAt = target > 0 ? target : nil
            self.userUpdatedPendingPausedIdentityReloadSeek = true
        }
        self.playbackController.seekWithRecovery(to: target)
    }

    private func clampedSeekTarget(_ time: Double) -> Double {
        if self.duration > 0 {
            return min(max(time, 0), self.duration)
        }
        return max(time, 0)
    }

    private func handleManualSeekToEnd() {
        guard self.currentVideo != nil, self.duration > 0 else { return }
        let terminalSeekTime = max(0, self.duration - Self.seekToEndThreshold)
        self.progress = self.duration
        self.lastNonAdContentProgress = self.duration
        self.clearPendingUserSeek()
        self.clearRelativeSeekCoalescingTarget()
        if self.pendingPausedIdentityReloadVideoId == self.currentVideo?.videoId {
            self.pendingPausedIdentityReloadResumeAt = nil
            self.userUpdatedPendingPausedIdentityReloadSeek = true
        }

        // Fence native pause intent before any WebView command can synchronously
        // publish a late playing sample, then cancel every older deferred seek so
        // it cannot overwrite this terminal position after the command returns.
        self.activateExplicitPauseIntent()
        self.pendingPausedIdentityReloadVideoId = nil
        self.pendingPausedIdentityReloadResumeAt = nil
        self.userUpdatedPendingPausedIdentityReloadSeek = true
        self.playbackController.cancelPendingRecoverySeek()
        self.playbackController.markCurrentPlaybackOccurrenceEnded()
        // Keep the WebView away from exact-duration seeks and pause it so a
        // follow-up state update cannot look like a fresh replay of the just-
        // concluded watch.
        self.playbackController.seek(to: terminalSeekTime)
        self.playbackController.pause()
        self.handleVideoEnded(
            videoId: self.currentVideo?.videoId,
            isNativeTerminal: true
        )
    }

    /// Seeks backward by a fixed interval, clamping to the beginning.
    func seekBackward(by seconds: Double = 30) {
        guard seconds.isFinite, seconds > 0 else { return }
        self.beginYouTubePlaybackIntent()
        self.seekRelative(by: -seconds)
    }

    /// Seeks forward by a fixed interval, clamping to the known duration.
    func seekForward(by seconds: Double = 30) {
        guard seconds.isFinite, seconds > 0 else { return }
        self.beginYouTubePlaybackIntent()
        self.seekRelative(by: seconds)
    }

    private func seekRelative(by delta: Double) {
        guard delta.isFinite, delta != 0, self.currentVideo != nil else { return }
        let now = ContinuousClock.now
        let currentVideoId = self.currentVideo?.videoId
        if self.lastRelativeSeekVideoId != currentVideoId {
            self.clearRelativeSeekCoalescingTarget()
        }
        self.lastRelativeSeekVideoId = currentVideoId

        // Bridge progress can lag behind rapid button repeats. Briefly use the
        // last command target so repeated clicks accumulate from user intent
        // instead of from a stale 1 Hz observer tick.
        let baseProgress = if self.canCoalesceRelativeSeekTarget(at: now),
                              let lastRelativeSeekTarget = self.lastRelativeSeekTarget
        {
            lastRelativeSeekTarget
        } else {
            self.progress
        }

        let target = self.clampedSeekTarget(baseProgress + delta)
        self.lastRelativeSeekTarget = target
        self.lastRelativeSeekIssuedAt = now
        self.performSeek(to: target)
    }

    private func canCoalesceRelativeSeekTarget(at now: ContinuousClock.Instant) -> Bool {
        guard let lastRelativeSeekIssuedAt = self.lastRelativeSeekIssuedAt else { return false }
        return now - lastRelativeSeekIssuedAt <= Self.relativeSeekTargetCoalescingWindow
    }

    func clearRelativeSeekCoalescingTarget() {
        self.lastRelativeSeekTarget = nil
        self.lastRelativeSeekIssuedAt = nil
        self.lastRelativeSeekVideoId = nil
    }
}
