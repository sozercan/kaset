import Testing
@testable import Kaset

@Suite("YouTube watch playback lifecycle", .serialized)
@MainActor
struct YouTubeWatchPlaybackLifecycleTests {
    @Test("Initial presentation starts a new video inline")
    func initialPresentationStartsInline() {
        let controller = MockYouTubeWatchPlaybackController()
        let player = YouTubePlayerService(
            playbackController: controller,
            shouldPopOutOnNavigateAway: { true }
        )
        let video = MockYouTubeClient.makeVideo(videoId: "video-a")

        YouTubeWatchPlaybackLifecycle.presentSurface(
            video: video,
            player: player,
            usesCookieFreeDataStore: false,
            data: .empty
        )

        #expect(player.currentVideo?.videoId == video.videoId)
        #expect(player.surfaceLocation == .inline)
        #expect(player.activeInlineVideoId == video.videoId)
        #expect(controller.loadedVideoIds == [video.videoId])
    }

    @Test("Initial presentation adopts and docks the matching floating video")
    func initialPresentationAdoptsMatchingFloatingVideo() {
        let controller = MockYouTubeWatchPlaybackController()
        let player = YouTubePlayerService(
            playbackController: controller,
            shouldPopOutOnNavigateAway: { true }
        )
        let video = MockYouTubeClient.makeVideo(videoId: "video-a")
        player.play(video: video)
        player.popOutToWindow()

        YouTubeWatchPlaybackLifecycle.presentSurface(
            video: video,
            player: player,
            usesCookieFreeDataStore: false,
            data: .empty
        )

        #expect(player.surfaceLocation == .inline)
        #expect(player.activeInlineVideoId == video.videoId)
        #expect(controller.loadedVideoIds == [video.videoId])
    }

    @Test("Account-scope refresh preserves a user-controlled floating surface")
    func accountScopeRefreshPreservesFloatingSurface() {
        let controller = MockYouTubeWatchPlaybackController()
        let player = YouTubePlayerService(
            playbackController: controller,
            shouldPopOutOnNavigateAway: { true }
        )
        let video = MockYouTubeClient.makeVideo(videoId: "video-a")
        let related = MockYouTubeClient.makeVideo(videoId: "video-b")
        let chapter = YouTubeChapter(
            videoId: video.videoId,
            title: "Chapter",
            startTime: 10,
            endTime: 20,
            timeText: "0:10",
            thumbnailURL: nil
        )
        player.play(video: video)
        player.activeInlineVideoId = video.videoId
        player.popOutToWindow()

        YouTubeWatchPlaybackLifecycle.synchronizeLoadedData(
            videoId: video.videoId,
            player: player,
            data: WatchNextData(
                videoTitle: nil,
                viewCountText: nil,
                publishedText: nil,
                channel: nil,
                related: [related],
                chapters: [chapter]
            )
        )

        #expect(player.surfaceLocation == .floating)
        #expect(player.currentVideo?.videoId == video.videoId)
        #expect(player.upNext.map(\.videoId) == [related.videoId])
        #expect(player.chapters == [chapter])
        #expect(controller.loadedVideoIds == [video.videoId])
    }

    @Test("Account-scope refresh cannot overwrite another video's companion data")
    func accountScopeRefreshDoesNotOverwriteAnotherVideo() {
        let controller = MockYouTubeWatchPlaybackController()
        let player = YouTubePlayerService(
            playbackController: controller,
            shouldPopOutOnNavigateAway: { true }
        )
        let currentVideo = MockYouTubeClient.makeVideo(videoId: "video-a")
        let existingRelated = MockYouTubeClient.makeVideo(videoId: "video-b")
        let replacementRelated = MockYouTubeClient.makeVideo(videoId: "video-c")
        let existingChapter = YouTubeChapter(
            videoId: currentVideo.videoId,
            title: "Existing",
            startTime: 0,
            endTime: 10,
            timeText: "0:00",
            thumbnailURL: nil
        )
        let replacementChapter = YouTubeChapter(
            videoId: "other-video",
            title: "Replacement",
            startTime: 10,
            endTime: 20,
            timeText: "0:10",
            thumbnailURL: nil
        )
        player.play(video: currentVideo)
        player.setUpNext([existingRelated])
        player.setChapters([existingChapter])
        player.popOutToWindow()

        YouTubeWatchPlaybackLifecycle.synchronizeLoadedData(
            videoId: "other-video",
            player: player,
            data: WatchNextData(
                videoTitle: nil,
                viewCountText: nil,
                publishedText: nil,
                channel: nil,
                related: [replacementRelated],
                chapters: [replacementChapter]
            )
        )

        #expect(player.surfaceLocation == .floating)
        #expect(player.upNext.map(\.videoId) == [existingRelated.videoId])
        #expect(player.chapters == [existingChapter])
        #expect(controller.loadedVideoIds == [currentVideo.videoId])
    }
}
