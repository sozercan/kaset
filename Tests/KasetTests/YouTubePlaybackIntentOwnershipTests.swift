import Testing
@testable import Kaset

@Suite("YouTube playback intent ownership", .serialized, .tags(.service), .timeLimit(.minutes(1)))
@MainActor
struct YouTubePlaybackIntentOwnershipTests {
    @Test("SPA drift uses bridge event time for remote-command admission")
    func driftUsesBridgeEventTimeForRemoteCommandAdmission() {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(playbackController: controller)
        service.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        service.youtubePlaybackIntentIssuedAtMilliseconds = 1000

        service.updatePlaybackState(.init(
            isPlaying: true,
            progress: 0,
            duration: 60,
            videoId: "xyz",
            title: "Drifted Title",
            eventIssuedAtMilliseconds: 1500
        ))
        service.handleRemotePause(issuedAtMilliseconds: 1600)

        #expect(controller.pauseCount == 1)
    }

    @Test("A same-timestamp native intent invalidates an older delayed skip")
    func sameTimestampNativeIntentInvalidatesDelayedSkip() async {
        let service = YouTubePlayerService(playbackController: MockYouTubeWatchPlaybackController())
        let client = MockYouTubeClient()
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        client.watchNextData = WatchNextData(
            videoTitle: nil,
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [MockYouTubeClient.makeVideo(videoId: "stale-next")]
        )
        client.beforeWatchNextReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }
        service.youtubeClient = client
        service.play(video: MockYouTubeClient.makeVideo(videoId: "current"))

        let skipTask = Task { @MainActor in
            await service.skipForward()
        }
        await requestStarted.wait()
        service.beginYouTubePlaybackIntent(
            issuedAtMilliseconds: service.youtubePlaybackIntentIssuedAtMilliseconds
        )
        await releaseRequest.open()
        await skipTask.value

        #expect(service.currentVideo?.videoId == "current")
    }

    @Test("Remote resume preserves its captured timestamp for ended-event ordering")
    func remoteResumePreservesCapturedTimestamp() {
        let service = YouTubePlayerService(playbackController: MockYouTubeWatchPlaybackController())
        let video = MockYouTubeClient.makeVideo(videoId: "remote-resume-timestamp")
        service.play(video: video)
        service.youtubePlaybackIntentIssuedAtMilliseconds = 1000

        service.handleRemoteResume(issuedAtMilliseconds: 2000)

        #expect(service.handleVideoEnded(
            videoId: video.videoId,
            eventIssuedAtMilliseconds: 2100
        ))
    }

    @Test("Remote toggle resume preserves its captured timestamp for ended-event ordering")
    func remoteToggleResumePreservesCapturedTimestamp() {
        let service = YouTubePlayerService(playbackController: MockYouTubeWatchPlaybackController())
        let video = MockYouTubeClient.makeVideo(videoId: "remote-toggle-timestamp")
        service.play(video: video)
        service.performPause()
        service.youtubePlaybackIntentIssuedAtMilliseconds = 1000

        service.handleRemoteTogglePlayPause(issuedAtMilliseconds: 2000)

        #expect(service.handleVideoEnded(
            videoId: video.videoId,
            eventIssuedAtMilliseconds: 2100
        ))
    }

    @Test("A native intent resets a future-poisoned remote-command boundary")
    func nativeIntentResetsFutureBoundary() {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(playbackController: controller)
        service.youtubePlaybackIntentIssuedAtMilliseconds = 9_000_000_000_000_000

        service.beginYouTubePlaybackIntent()
        let recoveredBoundary = service.youtubePlaybackIntentIssuedAtMilliseconds
        service.handleRemoteResume(issuedAtMilliseconds: 9_000_000_000_000_000)
        service.handleRemotePause(issuedAtMilliseconds: recoveredBoundary + 1)

        #expect(recoveredBoundary < 9_000_000_000_000_000)
        #expect(controller.playCount == 0)
        #expect(controller.pauseCount == 1)
    }

    @Test("An equal-timestamp native intent clears remote-command ownership")
    func equalTimestampNativeIntentClearsRemoteOwnership() {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(playbackController: controller)
        service.youtubePlaybackIntentIssuedAtMilliseconds = 1000
        service.handleRemotePause(issuedAtMilliseconds: 2000)

        service.beginYouTubePlaybackIntent(issuedAtMilliseconds: 2000)
        service.handleRemoteResume(issuedAtMilliseconds: 2000)

        #expect(controller.pauseCount == 1)
        #expect(controller.playCount == 0)
    }

    @Test("An older bridge intent preserves newer remote-command ownership")
    func olderBridgeIntentPreservesRemoteOwnership() {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(playbackController: controller)
        service.youtubePlaybackIntentIssuedAtMilliseconds = 1000
        service.handleRemotePause(issuedAtMilliseconds: 2000)

        service.beginYouTubePlaybackIntent(issuedAtMilliseconds: 1500)
        service.handleRemoteResume(issuedAtMilliseconds: 2000)

        #expect(controller.pauseCount == 1)
        #expect(controller.playCount == 1)
    }

    @Test("A stale remote next command cannot navigate after a newer native intent")
    func staleRemoteNextCannotNavigate() async {
        let service = YouTubePlayerService(playbackController: MockYouTubeWatchPlaybackController())
        service.play(video: MockYouTubeClient.makeVideo(videoId: "current"))
        service.setUpNext([MockYouTubeClient.makeVideo(videoId: "stale-next")])
        service.beginYouTubePlaybackIntent(issuedAtMilliseconds: 2000)

        await service.handleRemoteSkipForward(issuedAtMilliseconds: 1000)

        #expect(service.currentVideo?.videoId == "current")
    }
}
