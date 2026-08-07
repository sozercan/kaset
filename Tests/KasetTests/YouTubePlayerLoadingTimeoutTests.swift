import Testing
@testable import Kaset

@Suite("YouTube loading timeout", .serialized, .tags(.service))
@MainActor
struct YouTubePlayerLoadingTimeoutTests {
    @Test("Settled empty media becomes reloadable after the bounded fallback")
    func emptyMediaBecomesReloadableAfterTimeout() async throws {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(
            playbackController: controller,
            playbackLoadingTimeout: .milliseconds(10)
        )
        service.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        service.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 0,
            hasReadyMedia: false,
            hasMediaError: false,
            videoId: "abc"
        ))

        #expect(service.isPlaybackLoading)
        try await self.waitUntil { !service.isPlaybackLoading }
        #expect(!service.isPlaybackLoading)
        #expect(controller.cancelPendingLoadCount == 1)
        #expect(service.pendingPausedIdentityReloadVideoId == "abc")

        service.playPause()

        #expect(controller.reloadedVideoIds == ["abc"])
        #expect(controller.playCount == 0)
        #expect(controller.pauseCount == 0)
    }

    @Test("A pre-ready SPA drift restarts the bounded loading fallback")
    func preReadyDriftRestartsLoadingTimeout() async throws {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(
            playbackController: controller,
            playbackLoadingTimeout: .milliseconds(10)
        )
        service.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        service.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 0,
            hasReadyMedia: false,
            hasMediaError: false,
            videoId: "b",
            boundVideoId: "a"
        ))

        #expect(service.currentVideo?.videoId == "b")
        #expect(service.isPlaybackLoading)
        try await self.waitUntil { !service.isPlaybackLoading }
        #expect(!service.isPlaybackLoading)
    }

    @Test("A timed-out active navigation is cancelled before it is deferred")
    func timedOutActiveNavigationIsCancelled() async throws {
        let controller = MockYouTubeWatchPlaybackController()
        controller.cancelPendingLoadResult = true
        let service = YouTubePlayerService(
            playbackController: controller,
            playbackLoadingTimeout: .milliseconds(10)
        )
        controller.onCancelPendingLoad = { [weak service] in
            service?.handleWebNavigationCancellation()
        }
        service.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        service.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 0,
            hasReadyMedia: false,
            hasMediaError: false,
            videoId: "abc"
        ))

        try await self.waitUntil { !service.isPlaybackLoading }

        #expect(controller.cancelPendingLoadCount == 1)
        #expect(service.pendingPausedIdentityReloadVideoId == "abc")
        service.playPause()
        #expect(controller.reloadedVideoIds == ["abc"])
    }

    @Test("A late playing update cannot consume a timed-out deferred reload")
    func latePlayingUpdateCannotConsumeTimedOutReload() async throws {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(
            playbackController: controller,
            playbackLoadingTimeout: .milliseconds(10)
        )
        service.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        service.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 0,
            hasReadyMedia: false,
            hasMediaError: false,
            videoId: "abc"
        ))
        try await self.waitUntil { !service.isPlaybackLoading }

        service.updatePlaybackState(.init(
            isPlaying: true,
            progress: 0,
            duration: 100,
            hasReadyMedia: true,
            videoId: "abc",
            boundVideoId: "abc"
        ))

        #expect(service.pendingPausedIdentityReloadVideoId == "abc")
        #expect(controller.reloadedVideoIds.isEmpty)
        #expect(!service.isPlaying)
        #expect(controller.pauseCount == 1)

        service.playPause()
        #expect(controller.reloadedVideoIds == ["abc"])
    }

    @Test("An unready SPA drift starts loading after outgoing media was ready")
    func unreadyDriftStartsLoadingAfterReadyOutgoingMedia() {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(
            playbackController: controller,
            playbackLoadingTimeout: .seconds(1)
        )
        service.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        service.updatePlaybackState(.init(
            isPlaying: true,
            progress: 15,
            duration: 100,
            hasReadyMedia: true,
            videoId: "a",
            boundVideoId: "a"
        ))
        #expect(!service.isPlaybackLoading)

        service.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 0,
            hasReadyMedia: false,
            videoId: "b",
            boundVideoId: "a"
        ))

        #expect(service.currentVideo?.videoId == "b")
        #expect(service.isPlaybackLoading)
    }

    @Test("Ready outgoing media does not clear the incoming video's loading cycle")
    func readyOutgoingMediaDoesNotClearIncomingLoading() {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(
            playbackController: controller,
            playbackLoadingTimeout: .milliseconds(10)
        )
        service.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        service.updatePlaybackState(.init(
            isPlaying: true,
            progress: 15,
            duration: 100,
            hasReadyMedia: true,
            videoId: "b",
            boundVideoId: "a"
        ))

        #expect(service.currentVideo?.videoId == "b")
        #expect(service.isPlaybackLoading)
    }

    @Test("Ready incoming media completes loading after page drift")
    func readyIncomingMediaCompletesLoadingAfterDrift() {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(playbackController: controller)
        service.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        service.updatePlaybackState(.init(
            isPlaying: true,
            progress: 0,
            duration: 100,
            hasReadyMedia: true,
            videoId: "b",
            boundVideoId: "b"
        ))

        #expect(service.currentVideo?.videoId == "b")
        #expect(!service.isPlaybackLoading)
    }

    @Test("A stale ready advertisement does not clear a newer video's loading cycle")
    func staleReadyAdvertisementDoesNotClearIncomingLoading() {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(
            playbackController: controller,
            playbackLoadingTimeout: .milliseconds(10)
        )
        service.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        service.play(video: MockYouTubeClient.makeVideo(videoId: "b"))
        service.updatePlaybackState(.init(
            isPlaying: true,
            progress: 0,
            duration: 15,
            hasReadyMedia: true,
            videoId: "creative",
            boundVideoId: "a",
            isAd: true
        ))

        #expect(service.currentVideo?.videoId == "b")
        #expect(service.isPlaybackLoading)
    }

    @Test("A timed-out identity reload remains retryable after pause and resume")
    func timedOutIdentityReloadRemainsRetryable() async throws {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(
            playbackController: controller,
            playbackLoadingTimeout: .milliseconds(10)
        )
        service.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        service.updatePlaybackState(.init(
            isPlaying: true,
            progress: 12,
            duration: 100,
            hasReadyMedia: true,
            videoId: "abc",
            boundVideoId: "abc"
        ))

        service.reloadCurrentVideoForIdentitySwitch()
        try await self.waitUntil { !service.isPlaybackLoading }
        #expect(!service.isPlaybackLoading)

        service.pause()
        service.resume()

        #expect(controller.reloadedVideoIds == ["abc", "abc"])
        #expect(controller.playCount == 0)
    }

    @Test("A same-video replacement load receives its own timeout window")
    func sameVideoReplacementReceivesIndependentTimeout() async throws {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(
            playbackController: controller,
            playbackLoadingTimeout: .seconds(1)
        )
        service.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        try await Task.sleep(for: .milliseconds(700))
        service.reloadCurrentVideoForIdentitySwitch()
        try await Task.sleep(for: .milliseconds(400))

        #expect(service.isPlaybackLoading)

        try await self.waitUntil(
            timeout: .seconds(2),
            condition: { !service.isPlaybackLoading }
        )
        #expect(!service.isPlaybackLoading)
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
