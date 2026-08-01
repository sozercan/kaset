import Testing
@testable import Kaset

@Suite("YouTube player race regressions", .serialized, .tags(.service))
@MainActor
struct YouTubePlayerRaceRegressionTests {
    private let controller: MockYouTubeWatchPlaybackController
    private let sut: YouTubePlayerService

    init() {
        self.controller = MockYouTubeWatchPlaybackController()
        self.sut = YouTubePlayerService(playbackController: self.controller)
    }

    @Test("Paused identity drift preserves the new video's ready position")
    func pausedIdentityDriftPreservesReadyPosition() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 12,
            duration: 100,
            hasReadyMedia: true,
            videoId: "a",
            boundVideoId: "a"
        ))
        self.sut.pause()
        self.sut.reloadCurrentVideoForIdentitySwitch()

        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 37,
            duration: 90,
            hasReadyMedia: true,
            videoId: "b",
            boundVideoId: "b",
            title: "B"
        ))
        self.sut.resume()

        #expect(self.sut.currentVideo?.videoId == "b")
        #expect(self.controller.reloadedVideoIds == ["b"])
        #expect(self.controller.reloadResumeSeconds == [37])
    }

    @Test("Native seek-to-end immediately after replay concludes the new watch")
    func nativeSeekToEndAfterReplayConcludesNewWatch() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        let endedOccurrence = YouTubePlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 9,
            duration: 10,
            hasReadyMedia: true,
            videoId: "a",
            boundVideoId: "a",
            playbackOccurrence: endedOccurrence
        ))
        var endedCount = 0
        self.sut.onVideoEnded = { _ in endedCount += 1 }
        #expect(self.sut.handleVideoEnded(
            videoId: "a",
            playbackOccurrence: endedOccurrence
        ))

        self.sut.resume()
        self.sut.seek(to: 10)

        #expect(endedCount == 2)
        #expect(self.sut.watchConclusionGeneration == 2)
        #expect(self.controller.markCurrentPlaybackOccurrenceEndedCount == 1)
        #expect(!self.sut.handleVideoEnded(
            videoId: "a",
            playbackOccurrence: endedOccurrence
        ))
        #expect(endedCount == 2)
    }

    @Test("Identity reload preserves an unacknowledged user seek")
    func identityReloadPreservesPendingUserSeek() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 12,
            duration: 100,
            hasReadyMedia: true,
            videoId: "a",
            boundVideoId: "a"
        ))

        self.sut.seek(to: 45)
        self.sut.reloadCurrentVideoForIdentitySwitch()

        #expect(self.controller.pendingRecoverySeeks == [45])
        #expect(self.controller.reloadedVideoIds == ["a"])
        #expect(self.controller.reloadResumeSeconds == [45])
    }

    @Test("A bridge end in the resume millisecond is not stale")
    func sameMillisecondBridgeEndIsNotStale() {
        #expect(!YouTubePlayerService.isEndEventStale(
            eventIssuedAtMilliseconds: 1000,
            lastResumeIssuedAtMilliseconds: 1000.8
        ))
        #expect(YouTubePlayerService.isEndEventStale(
            eventIssuedAtMilliseconds: 999,
            lastResumeIssuedAtMilliseconds: 1000.8
        ))
    }

    @Test("Stop suppresses a late admitted playing update")
    func stopSuppressesLatePlayingUpdate() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 5,
            duration: 10,
            hasReadyMedia: true,
            videoId: "a",
            boundVideoId: "a"
        ))
        self.controller.resetCommandLog()

        self.sut.stop()
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 6,
            duration: 10,
            hasReadyMedia: true,
            videoId: "a",
            boundVideoId: "a"
        ))

        #expect(!self.sut.isPlaying)
        #expect(self.sut.currentVideo == nil)
        #expect(self.sut.progress == 0)
        #expect(self.sut.duration == 0)
        #expect(!self.sut.isShowingAd)
        #expect(!self.sut.isPlaybackLoading)
        #expect(self.controller.commandLog == ["pause"])
    }

    @Test("Exhausted seek retries do not resurrect an abandoned user target")
    func exhaustedSeekDoesNotResurrectUserTarget() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 12,
            duration: 100,
            hasReadyMedia: true,
            videoId: "a",
            boundVideoId: "a"
        ))
        self.sut.seek(to: 45)

        self.sut.handlePendingSeekExhausted(videoId: "a", target: 45)
        self.sut.reloadCurrentVideoForIdentitySwitch()

        #expect(self.controller.reloadResumeSeconds == [12])
    }

    @Test("Exhausted seek retries clear an unacknowledged explicit start")
    func exhaustedSeekClearsExplicitStartTarget() {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(playbackController: controller)
        service.play(
            video: MockYouTubeClient.makeVideo(videoId: "a"),
            startAt: 45
        )

        service.handlePendingSeekExhausted(videoId: "a", target: 45)
        service.handleWebNavigationFailure()
        service.resume()

        #expect(controller.reloadResumeSeconds.count == 2)
        #expect(controller.reloadResumeSeconds[0] == 45)
        #expect(controller.reloadResumeSeconds[1] == nil)
    }

    @Test("Exhausted seek retries repair a deferred identity reload target")
    func exhaustedSeekRepairsDeferredIdentityReload() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 12,
            duration: 100,
            hasReadyMedia: true,
            videoId: "a",
            boundVideoId: "a"
        ))
        self.sut.pause()
        self.sut.reloadCurrentVideoForIdentitySwitch()
        self.sut.seek(to: 45)

        self.sut.handlePendingSeekExhausted(videoId: "a", target: 45)
        self.sut.resume()

        #expect(self.controller.reloadResumeSeconds == [12])
        #expect(!self.sut.userUpdatedPendingPausedIdentityReloadSeek)
    }

    @Test("Terminal seek does not recreate an identity reload at the duration")
    func terminalSeekClearsInFlightIdentityReloadTarget() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 50,
            duration: 100,
            hasReadyMedia: true,
            videoId: "a",
            boundVideoId: "a"
        ))
        self.sut.reloadCurrentVideoForIdentitySwitch()
        #expect(self.controller.reloadResumeSeconds == [50])

        self.sut.seek(to: 100)
        self.sut.resume()

        #expect(self.controller.reloadResumeSeconds == [50])
        #expect(self.sut.pendingPausedIdentityReloadVideoId == nil)
        #expect(self.sut.pendingPausedIdentityReloadResumeAt == nil)
    }

    @Test("A pause-pending playing sample cannot confirm a newer resume")
    func pausePendingSampleDoesNotConfirmResume() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 10,
            duration: 100,
            hasReadyMedia: true,
            videoId: "a",
            boundVideoId: "a"
        ))
        self.sut.pause()
        self.sut.resume()

        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 10,
            duration: 100,
            hasReadyMedia: true,
            videoId: "a",
            boundVideoId: "a",
            nativePausePending: true
        ))
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 10,
            duration: 100,
            hasReadyMedia: true,
            videoId: "a",
            boundVideoId: "a"
        ))
        self.sut.recoverAfterWebContentProcessTermination()

        #expect(self.controller.reloadedVideoIds == ["a"])
        #expect(self.sut.pendingPausedIdentityReloadVideoId == nil)
    }

    @Test("A preroll ad creative is never promoted as the recovery target")
    func prerollAdCreativeIsNotRecoveryTarget() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        let firstOccurrence = YouTubePlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 59,
            duration: 60,
            hasReadyMedia: true,
            videoId: "a",
            boundVideoId: "a",
            playbackOccurrence: firstOccurrence
        ))
        self.sut.handleVideoEnded(
            videoId: "a",
            playbackOccurrence: firstOccurrence
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 7,
            duration: 15,
            hasReadyMedia: true,
            videoId: "b",
            boundVideoId: "b",
            title: "B",
            isAd: true,
            playbackOccurrence: YouTubePlaybackOccurrence(
                documentGeneration: 7,
                mediaGeneration: 2
            )
        ))
        self.sut.setUpNext([MockYouTubeClient.makeVideo(videoId: "b")])

        self.sut.recoverAfterWebContentProcessTermination()

        #expect(self.sut.currentVideo?.videoId == "a")
        #expect(self.controller.reloadedVideoIds.isEmpty)
        #expect(!self.sut.isPlaying)
        #expect(self.sut.pendingPausedIdentityReloadVideoId == nil)

        self.sut.resume()
        #expect(self.sut.currentVideo?.videoId == "b")
        #expect(self.controller.loadedVideoIds.last == "b")
    }

    @Test("A ready paused preroll remains a retryable autoplay transition")
    func pausedPrerollSurvivesProcessRecovery() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        let firstOccurrence = YouTubePlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 59,
            duration: 60,
            videoId: "a",
            playbackOccurrence: firstOccurrence
        ))
        self.sut.handleVideoEnded(videoId: "a", playbackOccurrence: firstOccurrence)
        self.sut.setUpNext([MockYouTubeClient.makeVideo(videoId: "b")])
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 15,
            hasReadyMedia: true,
            videoId: "creative",
            isAd: true,
            playbackOccurrence: YouTubePlaybackOccurrence(
                documentGeneration: 7,
                mediaGeneration: 2
            )
        ))

        self.sut.recoverAfterWebContentProcessTermination()
        #expect(self.controller.reloadedVideoIds.isEmpty)
        self.sut.resume()

        #expect(self.sut.currentVideo?.videoId == "b")
        #expect(self.controller.loadedVideoIds.last == "b")
    }

    @Test("Failed autoplay recovery remains retryable without stale advancement")
    func failedAutoplayRecoveryRemainsRetryable() async {
        let client = MockYouTubeClient()
        self.sut.youtubeClient = client
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        let firstOccurrence = YouTubePlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 59,
            duration: 60,
            videoId: "a",
            playbackOccurrence: firstOccurrence
        ))
        self.sut.handleVideoEnded(videoId: "a", playbackOccurrence: firstOccurrence)
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 2,
            duration: 15,
            hasReadyMedia: true,
            videoId: "creative",
            isAd: true,
            playbackOccurrence: YouTubePlaybackOccurrence(
                documentGeneration: 7,
                mediaGeneration: 2
            )
        ))
        self.sut.recoverAfterWebContentProcessTermination()

        self.sut.resume()
        await Task.yield()
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "newer"))
        await Task.yield()

        #expect(self.sut.currentVideo?.videoId == "newer")
        self.sut.playPause()
        #expect(self.controller.pauseCount >= 1)
    }
}
