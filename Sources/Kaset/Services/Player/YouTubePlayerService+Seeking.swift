import Foundation

@MainActor
extension YouTubePlayerService {
    private static let seekToEndThreshold: TimeInterval = 0.5

    private static let relativeSeekTargetCoalescingWindow: Duration = .seconds(1)

    func seek(to time: Double) {
        guard !self.isShowingAd else { return }
        self.beginYouTubePlaybackIntent()
        self.clearRelativeSeekCoalescingTarget()
        self.performSeek(to: time)
    }

    func handleRemoteSeek(
        to time: Double,
        issuedAtMilliseconds: Double
    ) {
        guard !self.isShowingAd, self.admitYouTubeRemoteCommand(
            issuedAtMilliseconds: issuedAtMilliseconds
        ) else { return }
        self.clearRelativeSeekCoalescingTarget()
        self.performSeek(to: time)
    }

    private func performSeek(to time: Double) {
        guard time.isFinite else { return }
        self.invalidateExplicitStartTargetForUserSeek()
        let target = self.clampedSeekTarget(time)
        if self.currentVideo?.isLive != true,
           !self.currentMediaIsLive,
           self.duration > 0,
           target >= self.duration - Self.seekToEndThreshold
        {
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

        self.activateExplicitPauseIntent()
        self.pendingPausedIdentityReloadVideoId = nil
        self.pendingPausedIdentityReloadResumeAt = nil
        self.userUpdatedPendingPausedIdentityReloadSeek = true
        self.playbackController.cancelPendingRecoverySeek()
        self.playbackController.markCurrentPlaybackOccurrenceEnded()
        self.playbackController.seek(to: terminalSeekTime)
        self.playbackController.pause()
        self.handleVideoEnded(
            videoId: self.currentVideo?.videoId,
            isNativeTerminal: true
        )
    }

    func seekBackward(by seconds: Double = 30) {
        guard !self.isShowingAd, seconds.isFinite, seconds > 0 else { return }
        self.beginYouTubePlaybackIntent()
        self.seekRelative(by: -seconds)
    }

    func seekForward(by seconds: Double = 30) {
        guard !self.isShowingAd, seconds.isFinite, seconds > 0 else { return }
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
