import Testing
@testable import Kaset

@Suite("YouTube player recovery", .serialized, .tags(.service))
@MainActor
struct YouTubePlayerRecoveryTests {
    private let controller: MockYouTubeWatchPlaybackController
    private let sut: YouTubePlayerService

    init() {
        self.controller = MockYouTubeWatchPlaybackController()
        self.sut = YouTubePlayerService(playbackController: self.controller)
    }

    @Test("WebContent recovery reloads a playing video at its content position")
    func webContentRecoveryReloadsPlayingVideo() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 42,
            duration: 100,
            hasReadyMedia: true,
            videoId: "abc",
            boundVideoId: "abc"
        ))

        self.sut.recoverAfterWebContentProcessTermination()

        #expect(self.controller.reloadedVideoIds == ["abc"])
        #expect(self.controller.reloadResumeSeconds == [42])
        #expect(self.sut.isPlaybackLoading)
        #expect(!self.sut.isPlaying)
    }

    @Test("Recovery clock follows ready bound media, not leading metadata")
    func recoveryClockIsBoundToPhysicalVideo() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 42,
            duration: 100,
            hasReadyMedia: true,
            videoId: "a",
            boundVideoId: "a"
        ))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 43,
            duration: 100,
            hasReadyMedia: true,
            videoId: "b",
            boundVideoId: "a",
            title: "B"
        ))

        self.sut.reloadCurrentVideoForIdentitySwitch()
        #expect(self.controller.reloadResumeSeconds.count == 1)
        #expect(self.controller.reloadResumeSeconds[0] == nil)

        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 5,
            duration: 100,
            hasReadyMedia: true,
            videoId: "b",
            boundVideoId: "b",
            title: "B"
        ))
        self.sut.reloadCurrentVideoForIdentitySwitch()
        #expect(self.controller.reloadResumeSeconds.last == 5)
    }

    @Test("A stale terminal seek attempt cannot clear a newer recovery seek")
    func staleTerminalAttemptCannotClearNewSeek() {
        let webView = YouTubeWatchWebView.shared
        let generation: UInt64 = 42
        webView.pendingSeeksByGeneration[generation] = 30
        webView.pendingSeekVideoIdsByGeneration[generation] = "abc"
        webView.pendingSeekAttemptIDsByGeneration[generation] = 2
        defer {
            webView.pendingSeeksByGeneration.removeValue(forKey: generation)
            webView.pendingSeekVideoIdsByGeneration.removeValue(forKey: generation)
            webView.pendingSeekAttemptIDsByGeneration.removeValue(forKey: generation)
        }

        let didAcceptStaleAttempt = webView.completePendingSeek(
            generation: generation,
            attemptID: 1,
            target: 30,
            videoId: "abc"
        )

        #expect(!didAcceptStaleAttempt)
        #expect(webView.pendingSeeksByGeneration[generation] == 30)

        let didAcceptCurrentAttempt = webView.completePendingSeek(
            generation: generation,
            attemptID: 2,
            target: 30,
            videoId: "abc"
        )

        #expect(didAcceptCurrentAttempt)
        #expect(webView.pendingSeeksByGeneration[generation] == nil)
    }

    @Test("Bound-media skew does not discard the active video's pending seek")
    func pendingSeekDiscardUsesNativeVideoIdentity() {
        #expect(!YouTubeWatchWebView.shouldDiscardPendingSeek(
            expectedVideoId: "b",
            activeVideoId: "b"
        ))
        #expect(YouTubeWatchWebView.shouldDiscardPendingSeek(
            expectedVideoId: "a",
            activeVideoId: "b"
        ))
        #expect(!YouTubeWatchWebView.shouldDiscardPendingSeek(
            expectedVideoId: "b",
            activeVideoId: nil
        ))
    }

    @Test("WebContent recovery keeps a paused video deferred until explicit resume")
    func webContentRecoveryDefersPausedVideo() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 42,
            duration: 100,
            hasReadyMedia: true,
            videoId: "abc",
            boundVideoId: "abc"
        ))
        self.sut.pause()

        self.sut.recoverAfterWebContentProcessTermination()

        #expect(self.controller.reloadedVideoIds.isEmpty)
        #expect(self.sut.pendingPausedIdentityReloadVideoId == "abc")
        #expect(self.sut.pendingPausedIdentityReloadResumeAt == 42)
        #expect(!self.sut.isPlaying)
        #expect(!self.sut.isPlaybackLoading)

        self.sut.resume()

        #expect(self.controller.reloadedVideoIds == ["abc"])
        #expect(self.controller.reloadResumeSeconds == [42])
    }

    @Test("Transient paused observer state while loading keeps automatic recovery intent")
    func transientPausedLoadingStateKeepsRecoveryIntent() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 42,
            duration: 100,
            hasReadyMedia: true,
            videoId: "abc",
            boundVideoId: "abc"
        ))

        self.sut.recoverAfterWebContentProcessTermination()

        #expect(self.controller.reloadedVideoIds == ["abc"])
        #expect(self.controller.reloadResumeSeconds == [42])
        #expect(self.sut.pendingPausedIdentityReloadVideoId == nil)
    }

    @Test("A settled never-started page resumes on the first toggle")
    func neverStartedPageNeedsOnePlayToggle() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 100,
            hasReadyMedia: true,
            videoId: "abc"
        ))

        self.sut.playPause()

        #expect(self.controller.playCount == 1)
        #expect(self.controller.pauseCount == 0)
    }

    @Test("A ready paused live stream resumes on the first toggle")
    func pausedLiveStreamNeedsOnePlayToggle() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "live"))
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 0,
            hasReadyMedia: true,
            videoId: "live"
        ))

        self.sut.playPause()

        #expect(self.controller.playCount == 1)
    }

    @Test("A ready paused preroll ad resumes on the first toggle")
    func pausedPrerollNeedsOnePlayToggle() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 15,
            hasReadyMedia: true,
            videoId: "abc",
            isAd: true
        ))

        self.sut.playPause()

        #expect(self.controller.playCount == 1)
    }

    @Test("Rapid toggles follow native command intent before observer catch-up")
    func rapidTogglesAlternateCommands() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 10,
            duration: 100,
            hasReadyMedia: true,
            videoId: "abc",
            boundVideoId: "abc"
        ))

        self.sut.playPause()
        self.sut.playPause()

        #expect(self.controller.pauseCount == 1)
        #expect(self.controller.playCount == 1)
    }

    @Test("A second toggle pauses while resume confirmation is outstanding")
    func secondToggleCancelsUnconfirmedResume() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 10,
            duration: 100,
            hasReadyMedia: true,
            videoId: "abc",
            boundVideoId: "abc"
        ))

        self.sut.playPause()
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 10,
            duration: 100,
            hasReadyMedia: true,
            videoId: "abc"
        ))
        self.sut.playPause()

        #expect(self.controller.playCount == 1)
        #expect(self.controller.pauseCount == 1)
    }

    @Test("Skipping clears the previous watch resume confirmation")
    func skipClearsResumeConfirmation() async {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        self.sut.resume()
        self.sut.setUpNext([MockYouTubeClient.makeVideo(videoId: "b")])

        await self.sut.skipForward()
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 100,
            hasReadyMedia: true,
            videoId: "b"
        ))
        self.sut.playPause()

        #expect(self.controller.pauseCount == 0)
        #expect(self.controller.playCount == 2)
    }

    @Test("A failed resume reload retries on the first subsequent toggle")
    func failedResumeReloadNeedsOneToggle() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.resume()
        self.sut.handleWebNavigationFailure()

        self.sut.playPause()

        #expect(self.controller.pauseCount == 0)
        #expect(self.controller.reloadedVideoIds.last == "abc")
    }

    @Test("A late pause acknowledgement cannot overwrite a newer resume")
    func latePauseAfterResumeKeepsPlayIntent() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 10,
            duration: 100,
            hasReadyMedia: true,
            videoId: "abc"
        ))
        self.sut.pause()
        self.sut.resume()
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 10,
            duration: 100,
            hasReadyMedia: true,
            videoId: "abc"
        ))

        self.sut.recoverAfterWebContentProcessTermination()

        #expect(self.controller.reloadedVideoIds == ["abc"])
        #expect(self.sut.pendingPausedIdentityReloadVideoId == nil)
    }

    @Test("An established playing-to-paused observer state becomes recovery pause intent")
    func observerPauseBecomesRecoveryIntent() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 10,
            duration: 100,
            hasReadyMedia: true,
            videoId: "abc",
            boundVideoId: "abc"
        ))
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 10,
            duration: 100,
            hasReadyMedia: true,
            videoId: "abc",
            boundVideoId: "abc"
        ))

        self.sut.recoverAfterWebContentProcessTermination()

        #expect(self.controller.reloadedVideoIds.isEmpty)
        #expect(self.sut.pendingPausedIdentityReloadVideoId == "abc")
        #expect(self.sut.pendingPausedIdentityReloadResumeAt == 10)
    }

    @Test("Play-pause explicitly pauses after cancelling an in-flight navigation")
    func consumedCancellationUsesExplicitPause() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 1,
            duration: 60,
            videoId: "abc"
        ))
        self.sut.reloadCurrentVideoForIdentitySwitch()
        self.controller.cancelPendingLoadResult = true

        self.sut.playPause()

        #expect(self.controller.cancelPendingLoadCount == 1)
        #expect(self.controller.pauseCount == 1)
        #expect(self.controller.playPauseCount == 0)
        #expect(!self.sut.isPlaying)
    }

    @Test("A late playing sample cannot overwrite explicit pause intent")
    func latePlayingSampleDoesNotOverwriteExplicitPause() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 10,
            duration: 60,
            videoId: "abc"
        ))

        self.sut.pause()
        let pausesAfterCommand = self.controller.pauseCount
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 10,
            duration: 60,
            videoId: "abc",
            nativePausePending: true
        ))

        #expect(!self.sut.isPlaying)
        #expect(self.controller.pauseCount == pausesAfterCommand + 1)

        self.sut.playPause()

        #expect(self.controller.playCount == 1)
        #expect(self.controller.pauseCount == pausesAfterCommand + 1)
    }

    @Test("Playing after a pause acknowledgement remains suppressed until native resume")
    func playingAfterPauseAcknowledgementRemainsSuppressed() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 10,
            duration: 60,
            videoId: "abc"
        ))
        self.sut.pause()
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 10,
            duration: 60,
            videoId: "abc"
        ))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 10,
            duration: 60,
            videoId: "abc"
        ))

        #expect(!self.sut.isPlaying)
        self.sut.resume()
        #expect(self.controller.playCount == 1)
    }

    @Test("A page-originated pause becomes authoritative after playback is established")
    func pagePauseUpdatesDesiredIntent() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 10,
            duration: 60,
            videoId: "abc"
        ))
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 10,
            duration: 60,
            hasReadyMedia: true,
            videoId: "abc"
        ))

        self.sut.playPause()

        #expect(self.controller.playCount == 1)
    }

    @Test("Explicit start target remains authoritative before its seek applies")
    func explicitStartTargetSurvivesPreSeekProgress() {
        self.sut.play(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            startAt: 120
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 1,
            duration: 300,
            videoId: "abc"
        ))

        self.sut.recoverAfterWebContentProcessTermination()

        #expect(self.controller.reloadResumeSeconds.last == 120)
    }

    @Test("Remembered progress far beyond an explicit start does not acknowledge the seek")
    func explicitStartTargetSurvivesUnrelatedLaterProgress() {
        self.sut.play(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            startAt: 120
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 300,
            duration: 400,
            videoId: "abc"
        ))

        self.sut.recoverAfterWebContentProcessTermination()

        #expect(self.controller.reloadResumeSeconds.last == 120)
    }

    @Test("A transient pending-seek failure preserves the native start target")
    func explicitStartTargetSurvivesSeekFailure() {
        self.sut.play(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            startAt: 120
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 300,
            hasReadyMedia: true,
            videoId: "abc",
            didFailPendingSeek: true
        ))

        self.sut.handleWebNavigationFailure()
        self.sut.resume()

        #expect(self.controller.reloadResumeSeconds == [120, 120])
    }

    @Test("An applied explicit start stays attributable before getVideoData is ready")
    func explicitStartAcknowledgementUsesPendingSeekIdentity() {
        self.sut.play(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            startAt: 120
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 120,
            duration: 300,
            videoId: nil,
            didApplyPendingSeek: true,
            pendingSeekTarget: 120,
            pendingSeekVideoId: "abc"
        ))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 180,
            duration: 300,
            hasReadyMedia: true,
            videoId: "abc",
            boundVideoId: "abc"
        ))

        self.sut.recoverAfterWebContentProcessTermination()

        #expect(self.controller.reloadResumeSeconds == [120, 180])
    }

    @Test("Process recovery rejects a seek owned by a different active video")
    func processRecoveryRejectsPreviousVideoSeek() {
        let resumeAt = YouTubeWatchWebView.recoverySeek(
            candidate: 12,
            candidateVideoId: "video-a",
            activeVideoId: "video-b"
        )
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "video-b"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 80,
            duration: 100,
            hasReadyMedia: true,
            videoId: "video-b",
            boundVideoId: "video-b"
        ))

        self.sut.recoverAfterWebContentProcessTermination(resumeAtOverride: resumeAt)

        #expect(resumeAt == nil)
        #expect(self.controller.reloadResumeSeconds == [80])
    }

    @Test("Navigation failure becomes retryable on explicit resume")
    func navigationFailureBecomesRetryable() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 42,
            duration: 100,
            hasReadyMedia: true,
            videoId: "abc",
            boundVideoId: "abc"
        ))

        self.sut.handleWebNavigationFailure()

        #expect(!self.sut.isPlaying)
        #expect(!self.sut.isPlaybackLoading)
        #expect(self.sut.pendingPausedIdentityReloadVideoId == "abc")
        #expect(self.sut.pendingPausedIdentityReloadResumeAt == 42)

        self.sut.resume()

        #expect(self.controller.reloadedVideoIds == ["abc"])
        #expect(self.controller.reloadResumeSeconds == [42])
    }

    @Test("Intentional navigation cancellation preserves the selected video for resume")
    func navigationCancellationPreservesSelectedVideo() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 42,
            duration: 100,
            hasReadyMedia: true,
            videoId: "abc",
            boundVideoId: "abc"
        ))

        self.sut.handleWebNavigationCancellation()

        #expect(!self.sut.isPlaying)
        #expect(self.sut.pendingPausedIdentityReloadVideoId == "abc")
        #expect(self.sut.pendingPausedIdentityReloadResumeAt == 42)

        self.sut.resume()
        #expect(self.controller.reloadedVideoIds == ["abc"])
        #expect(self.controller.reloadResumeSeconds == [42])
    }

    @Test("Accepted autoplay restores requested-play intent for process recovery")
    func autoplayRestoresRecoveryIntent() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 42,
            duration: 100,
            videoId: "abc"
        ))
        self.sut.handleVideoEnded(videoId: "abc")

        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 7,
            duration: 80,
            hasReadyMedia: true,
            videoId: "def",
            boundVideoId: "def",
            title: "Autoplayed"
        ))
        self.sut.recoverAfterWebContentProcessTermination()

        #expect(self.sut.currentVideo?.videoId == "def")
        #expect(self.controller.reloadedVideoIds == ["def"])
        #expect(self.sut.pendingPausedIdentityReloadVideoId == nil)
    }

    @Test("A different-video playing sample queued before explicit pause stays suppressed")
    func differentVideoDoesNotBypassExplicitPause() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 42,
            duration: 100,
            videoId: "abc"
        ))
        self.sut.pause()

        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 1,
            duration: 80,
            videoId: "def",
            title: "Queued autoplay",

            nativePausePending: true
        ))
        self.sut.recoverAfterWebContentProcessTermination()

        #expect(!self.sut.isPlaying)
        #expect(self.sut.currentVideo?.videoId == "def")
        #expect(self.controller.reloadedVideoIds.isEmpty)
        #expect(self.sut.pendingPausedIdentityReloadVideoId == "def")
    }

    @Test("A queued ended event cannot clear a newer explicit pause")
    func endedEventPreservesNewerExplicitPause() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 79,
            duration: 80,
            videoId: "abc"
        ))
        self.sut.pause()
        self.sut.handleVideoEnded(videoId: "abc")
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 1,
            duration: 90,
            hasReadyMedia: true,
            videoId: "def",
            boundVideoId: "def",
            title: "Autoplay",
            nativePausePending: true
        ))

        self.sut.recoverAfterWebContentProcessTermination()

        #expect(!self.sut.isPlaying)
        #expect(self.controller.reloadedVideoIds.isEmpty)
        #expect(self.sut.pendingPausedIdentityReloadVideoId == "def")
    }

    @Test("Interrupted explicit start targets survive every early recovery path")
    func interruptedStartAtIsPreserved() {
        let failureController = MockYouTubeWatchPlaybackController()
        let failureService = YouTubePlayerService(playbackController: failureController)
        failureService.play(
            video: MockYouTubeClient.makeVideo(videoId: "failure"),
            startAt: 42
        )
        failureService.handleWebNavigationFailure()
        failureService.resume()
        #expect(failureController.reloadResumeSeconds == [42, 42])

        let cancellationController = MockYouTubeWatchPlaybackController()
        let cancellationService = YouTubePlayerService(playbackController: cancellationController)
        cancellationService.play(
            video: MockYouTubeClient.makeVideo(videoId: "cancellation"),
            startAt: 84
        )
        cancellationService.handleWebNavigationCancellation()
        cancellationService.resume()
        #expect(cancellationController.reloadResumeSeconds == [84, 84])

        let processController = MockYouTubeWatchPlaybackController()
        let processService = YouTubePlayerService(playbackController: processController)
        processService.play(
            video: MockYouTubeClient.makeVideo(videoId: "process"),
            startAt: 126
        )
        processService.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 300,
            videoId: "process"
        ))
        processService.recoverAfterWebContentProcessTermination()
        #expect(processController.reloadResumeSeconds == [126, 126])

        let confirmedController = MockYouTubeWatchPlaybackController()
        let confirmedService = YouTubePlayerService(playbackController: confirmedController)
        confirmedService.play(
            video: MockYouTubeClient.makeVideo(videoId: "confirmed"),
            startAt: 168
        )
        confirmedService.updatePlaybackState(.init(
            isPlaying: true,
            progress: 168,
            duration: 300,
            videoId: "confirmed",
            didApplyPendingSeek: true
        ))
        confirmedService.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 300,
            videoId: "confirmed"
        ))
        confirmedService.handleWebNavigationFailure()
        confirmedService.resume()
        #expect(confirmedController.reloadResumeSeconds == [168, nil])
    }

    @Test("A user seek replaces an unconfirmed explicit start target for recovery")
    func userSeekInvalidatesExplicitStartTarget() {
        self.sut.play(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            startAt: 120
        )

        self.sut.seek(to: 30)
        #expect(self.controller.pendingRecoverySeeks == [30])
        self.sut.handleWebNavigationFailure(resumeAtOverride: 30)
        self.sut.resume()

        #expect(self.controller.reloadResumeSeconds == [120, 30])
    }

    @Test("Explicit start positions reject non-finite values and clamp oversized input")
    func explicitStartPositionsAreBounded() {
        #expect(YouTubePlayerService.normalizedExplicitStartAt(nil) == nil)
        #expect(YouTubePlayerService.normalizedExplicitStartAt(-1) == nil)
        #expect(YouTubePlayerService.normalizedExplicitStartAt(.infinity) == nil)
        #expect(YouTubePlayerService.normalizedExplicitStartAt(.nan) == nil)
        #expect(YouTubePlayerService.normalizedExplicitStartAt(42) == 42)
        #expect(YouTubePlayerService.normalizedExplicitStartAt(1_000_000) == 1_000_000)
    }

    @Test("WebContent recovery honors pause before the first observer update")
    func webContentRecoveryHonorsEarlyPause() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.pause()
        self.sut.recoverAfterWebContentProcessTermination()

        #expect(self.controller.reloadedVideoIds.isEmpty)
        #expect(self.sut.pendingPausedIdentityReloadVideoId == "abc")
    }
}
