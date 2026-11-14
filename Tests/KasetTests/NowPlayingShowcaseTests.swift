import Foundation
import Testing
@testable import Kaset

@MainActor
@Suite(.serialized)
struct NowPlayingShowcaseTests {
    @Test("Panel selection preserves the showcase and does not open another window", arguments: PlayerService.NowPlayingPanel.allCases)
    func selectPanel(panel: PlayerService.NowPlayingPanel) {
        let player = PlayerService()
        player.showNowPlayingShowcase = true
        player.nowPlayingPanel = nil

        player.nowPlayingPanel = panel

        #expect(player.showNowPlayingShowcase)
        #expect(player.nowPlayingPanel == panel)
        #expect(!player.showLyrics && !player.showQueue)
        #expect(!player.showVideo && !player.isMiniPlayerVisible)
    }

    @Test("Wide saved panels still leave room for artwork at the minimum window size")
    func minimumWindowLayout() {
        let size = CGSize(width: MainWindowLayout.minimumWidth, height: MainWindowLayout.minimumHeight)
        let width = NowPlayingShowcaseLayout.panelWidth(in: size.width, preferred: 560)
        let artwork = NowPlayingShowcaseLayout.artworkSize(in: size, panelWidth: width)

        #expect(width <= size.width * 0.46)
        #expect(artwork + width + 24 + 48 <= size.width)
        #expect(artwork + 264 <= size.height)
        #expect(artwork >= 160)
    }

    @Test("Recommendations filter the seed and duplicate tracks")
    func recommendations() async {
        let client = MockYTMusicClient()
        let song = Self.song("recommended")
        client.radioQueueSongs["seed"] = [Self.song("seed"), song, song]
        let model = ShowcaseRecommendationsModel()

        await model.load(videoId: "seed", client: client)

        #expect(model.songs.map(\.videoId) == ["recommended"])
        #expect(!model.isLoading && !model.hasError)
    }

    @Test("An old recommendation response cannot replace the current track's results")
    func staleRecommendations() async {
        let client = MockYTMusicClient()
        let started = AsyncGate()
        let release = AsyncGate()
        client.radioQueueSongs = ["old": [Self.song("old-result")], "new": [Self.song("new-result")]]
        client.beforeRadioQueueReturn = { videoId in
            if videoId == "old" {
                await started.open()
                await release.wait()
            }
        }
        let model = ShowcaseRecommendationsModel()
        let oldRequest = Task { await model.load(videoId: "old", client: client) }
        await started.wait()

        await model.load(videoId: "new", client: client)
        await release.open()
        await oldRequest.value

        #expect(model.songs.map(\.videoId) == ["new-result"])
        #expect(!model.isLoading && !model.hasError)
    }

    @Test("A failed recommendation request can be retried")
    func recommendationRetry() async {
        let client = MockYTMusicClient()
        client.radioQueueErrors["seed"] = YTMusicError.authExpired
        let model = ShowcaseRecommendationsModel()
        await model.load(videoId: "seed", client: client)
        #expect(model.hasError && !model.isLoading)

        client.radioQueueErrors = [:]
        client.radioQueueSongs["seed"] = [Self.song("retry-result")]
        await model.load(videoId: "seed", client: client)

        #expect(!model.hasError && !model.isLoading)
        #expect(model.songs.map(\.videoId) == ["retry-result"])
    }

    @Test("The bar's TV button opens the showcase with the video active when the showcase is closed")
    func tvButtonOpensShowcaseWithVideo() async {
        let player = PlayerService()
        var song = Self.song("video")
        song.musicVideoType = .omv
        player.currentTrack = song
        player.pendingPlayVideoId = song.videoId
        player.currentTrackHasVideo = true
        SingletonPlayerWebView.shared.currentVideoId = song.videoId
        defer { SingletonPlayerWebView.shared.currentVideoId = nil }

        // The showcase TV button's path: the showcase opens first, then the
        // overlay's TV toggle swaps to video.
        player.showNowPlayingShowcase = true
        await player.toggleNowPlayingVideo()

        #expect(player.showNowPlayingShowcase)
        #expect(player.showNowPlayingVideo)
        #expect(player.playbackViewHost == .showcase)
    }

    @Test("The bar's lyrics button morphs and toggles the showcase panel in place")
    func barLyricsMorphsShowcasePanel() {
        let player = PlayerService()
        player.showNowPlayingShowcase = true
        player.nowPlayingPanel = nil

        player.showLyrics = true
        #expect(player.nowPlayingPanel == .lyrics)
        #expect(!player.showLyrics)

        player.showLyrics = true
        #expect(player.nowPlayingPanel == nil)
    }

    @Test("Inline video replaces the artwork in the main column at 16:9", arguments: [CGFloat(980), 1200, 1800])
    func inlineVideoLayout(width: CGFloat) {
        let height: CGFloat = 720
        let panel = NowPlayingShowcaseLayout.panelWidth(in: width, preferred: 560)
        let video = NowPlayingShowcaseLayout.videoSize(in: CGSize(width: width, height: height), panelWidth: panel)
        #expect(video.width + panel + 24 + 48 <= width)
        #expect(video.height + 264 <= height)
        #expect(abs(video.width / video.height - 16.0 / 9.0) < 0.001)
    }

    @Test("Inline video preserves playback and takes over from a native video window")
    func inlineVideoTakeover() async {
        let player = Self.videoPlayer()
        player.progress = 42
        player.duration = 180
        player.state = .paused
        player.showVideo = true
        #expect(player.playbackViewHost == .videoWindow)

        await player.toggleNowPlayingVideo()

        #expect(!player.showVideo)
        #expect(player.showNowPlayingShowcase)
        #expect(player.playbackViewHost == .showcase)
        #expect(player.progress == 42 && player.duration == 180)
        #expect(player.state == .paused)
        #expect(player.isVideoGracePeriodActive)
        #expect(player.currentTrack?.videoId == "video")
    }

    @Test("An explicit TV action takes ownership from an auxiliary mini player")
    func inlineVideoTakesOverFromMiniPlayer() async {
        let player = Self.videoPlayer()
        player.openMiniPlayer(mode: .auxiliary)
        #expect(player.playbackViewHost == .miniPlayer)

        await player.toggleNowPlayingVideo()

        #expect(!player.isMiniPlayerVisible)
        #expect(!player.miniPlayerMainWindowRestoreRequest)
        #expect(player.showNowPlayingShowcase)
        #expect(player.playbackViewHost == .showcase)
    }

    @Test("Inline video yields to mini player and restores hidden mode when showcase closes")
    func inlineVideoHandoffs() async {
        let player = Self.videoPlayer()
        await player.toggleNowPlayingVideo()
        player.openMiniPlayer(mode: .auxiliary)
        #expect(player.playbackViewHost == .miniPlayer)
        #expect(!player.shouldHostPlaybackInShowcase)

        player.closeMiniPlayer()
        #expect(player.playbackViewHost == .showcase)

        player.showNowPlayingShowcase = false
        #expect(!player.showNowPlayingVideo)
        #expect(player.playbackViewHost == .mainWindow)
    }

    @Test("Native video takes ownership even during rapid inline toggles")
    func inlineVideoRapidToggle() async {
        let player = Self.videoPlayer()
        for _ in 0 ..< 4 {
            await player.toggleNowPlayingVideo()
            #expect(player.playbackViewHost == .showcase)
            await player.toggleNowPlayingVideo()
            #expect(player.playbackViewHost == .mainWindow)
        }
        await player.toggleNowPlayingVideo()
        player.showVideo = true
        #expect(!player.showNowPlayingVideo)
        #expect(player.playbackViewHost == .videoWindow)
    }

    @Test("Transient video availability cannot disable an active TV toggle")
    func inlineVideoAvailability() async {
        let player = PlayerService()
        var track = Self.song("video")
        track.musicVideoType = .omv
        player.currentTrack = track
        player.showNowPlayingShowcase = true
        SingletonPlayerWebView.shared.currentVideoId = track.videoId
        defer { SingletonPlayerWebView.shared.currentVideoId = nil }
        await player.toggleNowPlayingVideo()
        #expect(player.playbackViewHost == .showcase)

        player.updateVideoAvailability(hasVideo: false)
        #expect(player.playbackViewHost == .showcase)
        await player.toggleNowPlayingVideo()
        #expect(!player.showNowPlayingVideo)
        #expect(player.playbackViewHost == .mainWindow)
    }

    @Test("Optimistic video metadata never hosts the audio stream as video; the MV version is force-loaded")
    func inlineVideoOptimisticEvidenceForcesMVLoad() async {
        let player = PlayerService()
        var track = Self.song("audio-with-counterpart")
        track.musicVideoType = .atv
        track.companionMusicVideoId = "omv"
        player.currentTrack = track
        player.currentTrackHasVideo = true
        player.showNowPlayingShowcase = true
        // The audio recording is what the WebView has loaded; the observed
        // stream therefore carries no video (audio-only, videoWidth == 0).
        SingletonPlayerWebView.shared.currentVideoId = track.videoId
        defer { SingletonPlayerWebView.shared.currentVideoId = nil }

        await player.toggleNowPlayingVideo()

        // Video mode is active only because the MV version was force-loaded.
        #expect(player.showNowPlayingVideo)
        #expect(player.playbackViewHost == .showcase)
        #expect(player.pendingPlayVideoId == "omv")
        #expect(player.showcaseVideoSourceSwap?.audioSong.videoId == "audio-with-counterpart")
        #expect(player.showcaseVideoSourceSwap?.videoSong.videoId == "omv")
    }

    @Test("A TV press that resolves no music video keeps the artwork on")
    func inlineVideoUnresolvableMVKeepsArtwork() async {
        let player = PlayerService()
        var track = Self.song("audio-no-mv")
        player.currentTrack = track
        player.currentTrackHasVideo = true
        player.showNowPlayingShowcase = true
        SingletonPlayerWebView.shared.currentVideoId = track.videoId
        defer { SingletonPlayerWebView.shared.currentVideoId = nil }

        await player.toggleNowPlayingVideo()

        #expect(!player.showNowPlayingVideo)
        #expect(player.playbackViewHost == .mainWindow)
        #expect(player.showcaseVideoSourceSwap == nil)
    }

    @Test("Video mode persists across automatic advance and force-loads the next track's MV")
    func inlineVideoPersistsAcrossAdvance() async {
        let player = PlayerService()
        var first = Self.song("first-audio")
        first.musicVideoType = .atv
        first.companionMusicVideoId = "first-omv"
        player.currentTrack = first
        player.showNowPlayingShowcase = true
        SingletonPlayerWebView.shared.currentVideoId = "first-audio"
        defer { SingletonPlayerWebView.shared.currentVideoId = nil }
        await player.toggleNowPlayingVideo()
        #expect(player.showNowPlayingVideo)
        #expect(player.showcaseVideoSourceSwap?.videoSong.videoId == "first-omv")

        // Auto-advance: the didSet keeps video mode on, reverts the old swap
        // row, and schedules the continuation for the new track.
        var second = Self.song("second-audio")
        second.companionMusicVideoId = "second-omv"
        player.currentTrack = second
        #expect(player.showNowPlayingVideo)
        #expect(player.showcaseVideoSourceSwap == nil)

        // The advance's navigation lands (loadVideo commits currentVideoId) and
        // playback confirms; the continuation then force-loads the next MV.
        SingletonPlayerWebView.shared.currentVideoId = "second-audio"
        player.state = .playing
        await player.showcaseVideoAdvanceContinuation?.value

        #expect(player.showNowPlayingVideo)
        #expect(player.playbackViewHost == .showcase)
        #expect(player.pendingPlayVideoId == "second-omv")
        #expect(player.showcaseVideoSourceSwap?.audioSong.videoId == "second-audio")
        #expect(player.showcaseVideoSourceSwap?.videoSong.videoId == "second-omv")
    }

    @Test("Automatic advance to a track with no resolvable MV falls back to artwork")
    func inlineVideoAdvanceWithoutResolvableMVDismisses() async {
        let player = PlayerService()
        var first = Self.song("first")
        first.musicVideoType = .omv
        player.currentTrack = first
        player.showNowPlayingShowcase = true
        SingletonPlayerWebView.shared.currentVideoId = "first"
        defer { SingletonPlayerWebView.shared.currentVideoId = nil }
        await player.toggleNowPlayingVideo()
        #expect(player.showNowPlayingVideo)

        // Unknown metadata keeps video mode on and attempts the MV load; with
        // no companion and no search client, the fallback is artwork.
        player.currentTrack = Self.song("unknown")
        #expect(player.showNowPlayingVideo)
        SingletonPlayerWebView.shared.currentVideoId = "unknown"
        player.state = .playing
        await player.showcaseVideoAdvanceContinuation?.value

        #expect(!player.showNowPlayingVideo)
        #expect(player.playbackViewHost == .mainWindow)
        #expect(player.showcaseVideoSourceSwap == nil)
    }

    @Test("Automatic advance to an explicitly audio-only track returns to artwork")
    func inlineVideoAdvanceToAudioOnlyDismisses() async {
        let player = PlayerService()
        var first = Self.song("first")
        first.musicVideoType = .omv
        player.currentTrack = first
        player.showNowPlayingShowcase = true
        SingletonPlayerWebView.shared.currentVideoId = "first"
        defer { SingletonPlayerWebView.shared.currentVideoId = nil }
        await player.toggleNowPlayingVideo()
        #expect(player.showNowPlayingVideo)

        var audio = Self.song("audio-only")
        audio.musicVideoType = .atv
        player.currentTrack = audio
        // The advance keeps the surface up and attempts the MV; with no
        // companion and no search client the continuation falls back to artwork.
        SingletonPlayerWebView.shared.currentVideoId = "audio-only"
        await player.showcaseVideoAdvanceContinuation?.value

        #expect(!player.showNowPlayingVideo)
        #expect(player.playbackViewHost == .mainWindow)
    }

    @Test("Known audio-only tracks fall back to artwork, while positive video metadata wins")
    func inlineVideoTrackChanges() async {
        let player = Self.videoPlayer()
        await player.toggleNowPlayingVideo()
        var anotherVideo = Self.song("another-video")
        anotherVideo.musicVideoType = .atv
        anotherVideo.hasVideo = true
        player.currentTrack = anotherVideo
        #expect(player.playbackViewHost == .showcase)

        var audio = Self.song("audio")
        audio.musicVideoType = .atv
        player.currentTrack = audio
        // The advance keeps the surface up and attempts the MV; with no
        // companion and no search client the continuation falls back to artwork.
        SingletonPlayerWebView.shared.currentVideoId = "audio"
        await player.showcaseVideoAdvanceContinuation?.value
        #expect(!player.showNowPlayingVideo)
        #expect(player.playbackViewHost == .mainWindow)
    }

    @Test("Late audio-only metadata for the same track restores artwork")
    func inlineVideoLateAudioMetadata() async {
        let player = Self.videoPlayer()
        await player.toggleNowPlayingVideo()
        var loadingTrack = Self.song("loading")
        player.currentTrack = loadingTrack
        #expect(player.shouldHostPlaybackInShowcase)

        loadingTrack.musicVideoType = .atv
        player.currentTrack = loadingTrack

        #expect(!player.showNowPlayingVideo)
        #expect(player.playbackViewHost == .mainWindow)
    }

    @Test("Like updates preserve video enabled through live availability evidence")
    func inlineVideoLikeUpdate() async {
        let player = PlayerService()
        var track = Self.song("live-video")
        track.musicVideoType = .omv
        player.currentTrack = track
        player.showNowPlayingShowcase = true
        SingletonPlayerWebView.shared.currentVideoId = track.videoId
        defer { SingletonPlayerWebView.shared.currentVideoId = nil }
        await player.toggleNowPlayingVideo()
        #expect(player.shouldHostPlaybackInShowcase)

        track.likeStatus = .like
        player.currentTrack = track

        #expect(player.shouldHostPlaybackInShowcase)
    }

    @Test("TV toggle cannot start without both a showcase and video availability")
    func inlineVideoEntryGuards() async {
        let player = PlayerService()
        await player.toggleNowPlayingVideo()
        #expect(!player.showNowPlayingVideo)
        player.currentTrack = Self.song("audio")
        player.showNowPlayingShowcase = true
        await player.toggleNowPlayingVideo()
        #expect(!player.showNowPlayingVideo)
        player.currentTrackHasVideo = true
        player.showNowPlayingShowcase = false
        await player.toggleNowPlayingVideo()
        #expect(!player.showNowPlayingVideo)
    }

    @Test("A search-resolved MV keeps the recording's own title and duration")
    func inlineVideoSearchResolvedMVCarriesRecordingMetadata() {
        // Self.song sets duration 180 (the studio recording's length).
        let track = Self.song("studio")
        let recording = ResolvedShowcaseMusicVideo(
            videoId: "live-mv",
            title: "Song (Live At Saitama Super Arena, 2022)",
            duration: 254
        )

        let variant = PlayerService.videoVariant(of: track, musicVideo: recording)

        #expect(variant.videoId == "live-mv")
        #expect(variant.title == "Song (Live At Saitama Super Arena, 2022)")
        #expect(variant.duration == 254)
        #expect(variant.musicVideoType == .omv)
        #expect(variant.preferredAudioVideoId == "studio")

        // A companion-paired MV has no search metadata: the track's own
        // studio title/duration stand in until the player reports the real
        // recording's duration.
        let companionTrack = Song(
            id: "studio2",
            title: "studio2",
            artists: [],
            album: nil,
            duration: 200,
            thumbnailURL: nil,
            videoId: "studio2"
        )
        let companion = PlayerService.videoVariant(
            of: companionTrack,
            musicVideo: ResolvedShowcaseMusicVideo(videoId: "companion-mv", title: nil, duration: nil)
        )
        #expect(companion.title == "studio2")
        #expect(companion.duration == 200)
    }

    private static func videoPlayer() -> PlayerService {
        let player = PlayerService()
        var song = Self.song("video")
        song.musicVideoType = .omv
        player.currentTrack = song
        player.pendingPlayVideoId = song.videoId
        player.showNowPlayingShowcase = true
        // The OMV's own stream is what the WebView has loaded, so hosting it in
        // place is backed by real evidence (OMV type + loaded id).
        SingletonPlayerWebView.shared.currentVideoId = song.videoId
        return player
    }

    private static func song(_ id: String) -> Song {
        Song(id: id, title: id, artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: id)
    }
}
