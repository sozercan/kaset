import Foundation
import Testing
@testable import Kaset

// MARK: - MockYouTubeWatchPlaybackController

/// Records playback commands without touching a real WebView.
@MainActor
private final class MockYouTubeWatchPlaybackController: YouTubeWatchPlaybackControlling {
    private(set) var loadedVideoIds: [String] = []
    private(set) var playPauseCount = 0
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var seeks: [Double] = []
    private(set) var volumes: [Double] = []
    private(set) var tearDownCount = 0
    private(set) var prepareCount = 0

    func prepare(webKitManager _: WebKitManager, playerService _: YouTubePlayerService) {
        self.prepareCount += 1
    }

    func loadVideo(videoId: String) {
        self.loadedVideoIds.append(videoId)
    }

    func playPause() {
        self.playPauseCount += 1
    }

    func play() {
        self.playCount += 1
    }

    func pause() {
        self.pauseCount += 1
    }

    func seek(to time: Double) {
        self.seeks.append(time)
    }

    func setVolume(_ volume: Double) {
        self.volumes.append(volume)
    }

    func showAirPlayPicker() {}

    var captionTracks: [YouTubeCaptionTrack] = []
    var quality: [String] = []
    private(set) var selectedCaption: String??
    private(set) var selectedQuality: String?

    func availableCaptionTracks() async -> [YouTubeCaptionTrack] {
        self.captionTracks
    }

    var activeCaption: String?

    func currentCaptionLanguageCode() async -> String? {
        self.activeCaption
    }

    func setCaptionTrack(languageCode: String?) {
        self.selectedCaption = languageCode
    }

    func availableQualityLevels() async -> [String] {
        self.quality
    }

    func currentQualityLevel() async -> String? {
        self.quality.first
    }

    func setQualityLevel(_ level: String) {
        self.selectedQuality = level
    }

    func storyboardSpec(expectedVideoId _: String?) async -> String? {
        nil
    }

    func tearDown() {
        self.tearDownCount += 1
    }
}

// MARK: - YouTubePlayerServiceTests

@Suite("YouTubePlayerService", .serialized, .tags(.service), .timeLimit(.minutes(1)))
@MainActor
struct YouTubePlayerServiceTests {
    private let controller: MockYouTubeWatchPlaybackController
    private let sut: YouTubePlayerService

    init() {
        self.controller = MockYouTubeWatchPlaybackController()
        self.sut = YouTubePlayerService(playbackController: self.controller)
    }

    @Test("Initial state is empty")
    func initialState() {
        #expect(self.sut.currentVideo == nil)
        #expect(self.sut.isPlaying == false)
        #expect(self.sut.surfaceLocation == .none)
    }

    @Test("Play loads the video docked inline and signals the arbiter")
    func playLoadsInline() {
        var willStartCount = 0
        self.sut.playbackWillStart = { willStartCount += 1 }

        let video = MockYouTubeClient.makeVideo(videoId: "abc")
        self.sut.play(video: video)

        #expect(self.sut.currentVideo?.videoId == "abc")
        #expect(self.sut.surfaceLocation == .inline)
        #expect(self.controller.prepareCount == 1)
        #expect(self.controller.loadedVideoIds == ["abc"])
        #expect(willStartCount == 1)
    }

    @Test("State updates from the bridge are applied")
    func stateUpdates() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 12.5, duration: 120,
            videoId: "abc", title: nil, isAd: false
        ))

        #expect(self.sut.isPlaying)
        #expect(self.sut.progress == 12.5)
        #expect(self.sut.duration == 120)
        #expect(self.sut.isShowingAd == false)
    }

    @Test("Bridge playback start signals the arbiter (covers SPA autostart)")
    func bridgeStartSignalsArbiter() {
        var willStartCount = 0
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.playbackWillStart = { willStartCount += 1 }

        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 0, duration: 10,
            videoId: "abc", title: nil, isAd: false
        ))
        // Second update while already playing must not re-signal.
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 1, duration: 10,
            videoId: "abc", title: nil, isAd: false
        ))

        #expect(willStartCount == 1)
    }

    @Test("Follows SPA drift to a different video")
    func followsDrift() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 0, duration: 60,
            videoId: "xyz", title: "Drifted Title", isAd: false
        ))

        #expect(self.sut.currentVideo?.videoId == "xyz")
        #expect(self.sut.currentVideo?.title == "Drifted Title")
    }

    @Test("Inline disappearance while playing pops out to the floating window")
    func disappearWhilePlayingPopsOut() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.activeInlineVideoId = "abc"
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 0, duration: 10,
            videoId: "abc", title: nil, isAd: false
        ))

        self.sut.inlineSurfaceWillDisappear(videoId: "abc")

        #expect(self.sut.surfaceLocation == .floating)
        #expect(self.sut.currentVideo != nil)
    }

    @Test("Inline disappearance while paused stops playback")
    func disappearWhilePausedStops() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.activeInlineVideoId = "abc"

        self.sut.inlineSurfaceWillDisappear(videoId: "abc")

        #expect(self.sut.surfaceLocation == .none)
        #expect(self.sut.currentVideo == nil)
        #expect(self.controller.tearDownCount == 1)
    }

    @Test("Disappearance of a non-owning view is ignored")
    func disappearOfOtherViewIgnored() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.activeInlineVideoId = "abc"

        // A different watch view (e.g. the previous one in the stack) goes away.
        self.sut.inlineSurfaceWillDisappear(videoId: "other")

        #expect(self.sut.surfaceLocation == .inline)
        #expect(self.sut.activeInlineVideoId == "abc")
    }

    @Test("Video ended invokes the hook and clears isPlaying")
    func videoEnded() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 9, duration: 10,
            videoId: "abc", title: nil, isAd: false
        ))
        var endedVideoId: String?
        self.sut.onVideoEnded = { endedVideoId = $0 }

        self.sut.handleVideoEnded(videoId: "abc")

        #expect(self.sut.isPlaying == false)
        #expect(endedVideoId == "abc")
    }

    @Test("Volume changes forward to the playback controller")
    func volumeForwards() {
        self.sut.volume = 0.4
        #expect(self.controller.volumes == [0.4])
    }

    @Test("Like and dislike toggle through the client with reset on new video")
    func ratingToggles() async {
        let client = MockYouTubeClient()
        self.sut.youtubeClient = client
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        await self.sut.toggleLike()
        #expect(self.sut.currentRating == .like)

        await self.sut.toggleDislike()
        #expect(self.sut.currentRating == .dislike)

        await self.sut.toggleDislike()
        #expect(self.sut.currentRating == YouTubeRating.none)
        #expect(client.ratedVideos.map(\.videoId) == ["abc", "abc", "abc"])

        // A new video starts with no rating.
        await self.sut.toggleLike()
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "xyz"))
        #expect(self.sut.currentRating == YouTubeRating.none)
    }

    @Test("Rating failure rolls back the optimistic state")
    func ratingFailureRollsBack() async {
        let client = MockYouTubeClient()
        client.error = YTMusicError.authExpired
        self.sut.youtubeClient = client
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        await self.sut.toggleLike()

        #expect(self.sut.currentRating == YouTubeRating.none)
    }

    @Test("Skip forward plays the next up-next video and records history")
    func skipForwardUsesUpNext() async {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "first"))
        self.sut.setUpNext([
            MockYouTubeClient.makeVideo(videoId: "second"),
            MockYouTubeClient.makeVideo(videoId: "third"),
        ])

        await self.sut.skipForward()

        #expect(self.sut.currentVideo?.videoId == "second")
        #expect(self.controller.loadedVideoIds == ["first", "second"])
        // Inline surface: a navigation request opens the new watch view.
        #expect(self.sut.skipNavigationRequest?.videoId == "second")

        // Skip backward returns to the first video without re-recording it.
        self.sut.skipBackward()
        #expect(self.sut.currentVideo?.videoId == "first")
    }

    @Test("Skip forward fetches related lazily when no up-next is known")
    func skipForwardFetchesLazily() async {
        let client = MockYouTubeClient()
        client.watchNextData = WatchNextData(
            videoTitle: nil,
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [MockYouTubeClient.makeVideo(videoId: "fetched")]
        )
        self.sut.youtubeClient = client
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "first"))

        await self.sut.skipForward()

        #expect(self.sut.currentVideo?.videoId == "fetched")
    }

    @Test("Skip backward with no history restarts the video")
    func skipBackwardRestarts() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "only"))

        self.sut.skipBackward()

        #expect(self.sut.currentVideo?.videoId == "only")
        #expect(self.controller.seeks == [0])
    }

    @Test("Up-next filters out the current video and Shorts")
    func upNextFilters() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "current"))

        self.sut.setUpNext([
            MockYouTubeClient.makeVideo(videoId: "current"),
            YouTubeVideo(videoId: "a-short", title: "Short", isShort: true),
            MockYouTubeClient.makeVideo(videoId: "keeper"),
        ])

        #expect(self.sut.upNext.map(\.videoId) == ["keeper"])
    }

    @Test("Skipping while floating keeps the surface in the window")
    func skipWhileFloatingStaysFloating() async {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "first"))
        self.sut.popOutToWindow()
        self.sut.setUpNext([MockYouTubeClient.makeVideo(videoId: "second")])

        await self.sut.skipForward()

        #expect(self.sut.surfaceLocation == .floating)
        #expect(self.sut.skipNavigationRequest == nil)
    }

    @Test("Watch Later toggles through the client and resets per video")
    func watchLaterToggles() async {
        let client = MockYouTubeClient()
        self.sut.youtubeClient = client
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        await self.sut.toggleWatchLater()
        #expect(self.sut.isInWatchLater)
        #expect(client.watchLaterAdds == ["abc"])

        await self.sut.toggleWatchLater()
        #expect(self.sut.isInWatchLater == false)
        #expect(client.watchLaterRemovals == ["abc"])

        await self.sut.toggleWatchLater()
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "xyz"))
        #expect(self.sut.isInWatchLater == false)
    }

    @Test("Playback options load once per video and selections forward")
    func playbackOptions() async {
        self.controller.captionTracks = [
            YouTubeCaptionTrack(languageCode: "en", displayName: "English"),
        ]
        self.controller.quality = ["hd1080", "hd720", "auto"]
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        await self.sut.refreshPlaybackOptions()

        #expect(self.sut.captionTracks.count == 1)
        #expect(self.sut.qualityLevels == ["hd1080", "hd720", "auto"])

        self.sut.selectCaptionTrack(languageCode: "en")
        #expect(self.sut.activeCaptionLanguageCode == "en")
        #expect(self.controller.selectedCaption == "en")

        self.sut.selectQuality("hd720")
        #expect(self.sut.currentQuality == "hd720")
        #expect(self.controller.selectedQuality == "hd720")
    }

    @Test("Source switch pauses the docked video in place — no pop-out")
    func sourceSwitchPausesInPlace() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.activeInlineVideoId = "abc"
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 5, duration: 60,
            videoId: "abc", title: nil, isAd: false
        ))

        self.sut.prepareForSourceSwitch()
        self.sut.inlineSurfaceWillDisappear(videoId: "abc")

        #expect(self.controller.pauseCount == 1)
        #expect(self.sut.surfaceLocation == .inline)
        #expect(self.sut.currentVideo?.videoId == "abc")
        #expect(self.controller.tearDownCount == 0)

        // The suppression is one-shot: a later in-app navigation while
        // playing pops out as usual.
        self.sut.activeInlineVideoId = "abc"
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 6, duration: 60,
            videoId: "abc", title: nil, isAd: false
        ))
        self.sut.inlineSurfaceWillDisappear(videoId: "abc")
        #expect(self.sut.surfaceLocation == .floating)
    }

    @Test("Pop-in request only fires from the floating window")
    func popInRequest() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        // Inline: no request.
        self.sut.requestPopIn()
        #expect(self.sut.popInRequest == nil)

        self.sut.popOutToWindow()
        self.sut.requestPopIn()
        #expect(self.sut.popInRequest?.videoId == "abc")

        self.sut.consumePopInRequest()
        #expect(self.sut.popInRequest == nil)
    }

    @Test("Stop resets everything and tears down the WebView")
    func stopResets() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 5, duration: 10,
            videoId: "abc", title: nil, isAd: false
        ))

        self.sut.stop()

        #expect(self.sut.currentVideo == nil)
        #expect(self.sut.isPlaying == false)
        #expect(self.sut.progress == 0)
        #expect(self.sut.surfaceLocation == .none)
        #expect(self.controller.tearDownCount == 1)
    }
}

// MARK: - PlaybackArbiterTests

@Suite("PlaybackArbiter", .serialized, .tags(.service), .timeLimit(.minutes(1)))
@MainActor
struct PlaybackArbiterTests {
    @Test("Video start claims the active source and pauses playing music")
    func videoStartPausesMusic() {
        let playerService = PlayerService()
        let controller = MockYouTubeWatchPlaybackController()
        let youtubePlayer = YouTubePlayerService(playbackController: controller)
        let arbiter = PlaybackArbiter(playerService: playerService, youtubePlayerService: youtubePlayer)

        #expect(arbiter.activeSource == .music)

        youtubePlayer.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        #expect(arbiter.activeSource == .video)
        #expect(arbiter.routesMediaKeysToVideo)
    }

    @Test("Music start pauses a playing video and reclaims routing")
    func musicStartPausesVideo() {
        let playerService = PlayerService()
        let controller = MockYouTubeWatchPlaybackController()
        let youtubePlayer = YouTubePlayerService(playbackController: controller)
        let arbiter = PlaybackArbiter(playerService: playerService, youtubePlayerService: youtubePlayer)

        youtubePlayer.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        youtubePlayer.updatePlaybackState(.init(
            isPlaying: true, progress: 0, duration: 10,
            videoId: "abc", title: nil, isAd: false
        ))
        #expect(arbiter.activeSource == .video)

        arbiter.musicDidStartPlaying()

        #expect(arbiter.activeSource == .music)
        #expect(controller.pauseCount == 1)
        #expect(arbiter.routesMediaKeysToVideo == false)
    }

    @Test("Repeated music starts do not re-pause the video")
    func repeatedMusicStartsIdempotent() {
        let playerService = PlayerService()
        let controller = MockYouTubeWatchPlaybackController()
        let youtubePlayer = YouTubePlayerService(playbackController: controller)
        let arbiter = PlaybackArbiter(playerService: playerService, youtubePlayerService: youtubePlayer)

        arbiter.musicDidStartPlaying()
        arbiter.musicDidStartPlaying()

        #expect(controller.pauseCount == 0)
        #expect(arbiter.activeSource == .music)
    }
}

// MARK: - YouTubeWatchScriptTests

@Suite("YouTubeWatchWebView scripts", .tags(.service))
@MainActor
struct YouTubeWatchScriptTests {
    @Test("Observer script posts to the youtubePlayer bridge with both message types")
    func observerScriptContract() {
        let script = YouTubeWatchWebView.observerScript
        #expect(script.contains("webkit.messageHandlers.youtubePlayer"))
        #expect(script.contains("STATE_UPDATE"))
        #expect(script.contains("VIDEO_ENDED"))
        #expect(script.contains("movie_player"))
        #expect(script.contains("__kasetTargetVolume"))
    }

    @Test("Extraction script defines the callable hook and visibility chain")
    func extractionScriptContract() {
        let script = YouTubeWatchWebView.extractionScript
        #expect(script.contains("__kasetExtractVideo"))
        #expect(script.contains("kaset-yt-video-style"))
        #expect(script.contains("kaset-visible"))
        #expect(script.contains("ytp-chrome-bottom"))
    }

    @Test("Bootstrap script clamps the volume target")
    func bootstrapClampsVolume() {
        #expect(YouTubeWatchWebView.pageBootstrapScript(targetVolume: 2.0)
            .contains("__kasetTargetVolume = 1.0"))
        #expect(YouTubeWatchWebView.pageBootstrapScript(targetVolume: -1)
            .contains("__kasetTargetVolume = 0.0"))
    }
}
