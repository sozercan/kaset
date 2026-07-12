import Foundation
import Testing
@testable import Kaset

@Suite("Music playback request deduplication", .serialized, .tags(.service))
@MainActor
struct MusicPlaybackRequestDedupTests {
    @Test("A deduplicated same-song request preserves native playback state")
    func deduplicatedSongRequestPreservesPlaybackState() async {
        let videoId = "same-video"
        let (playerService, webKitManager) = self.makeLoadedPlayer(videoId: videoId)
        _ = webKitManager
        defer { SingletonPlayerWebView.shared.tearDown() }
        let song = Song(
            id: "same-song",
            title: "Same Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: videoId
        )
        self.seedPausedPlayback(playerService, song: song)

        await playerService.play(song: song)

        #expect(playerService.state == .paused)
        #expect(playerService.progress == 42)
        #expect(playerService.currentTimeMs == 42000)
        #expect(playerService.duration == 180)
        #expect(playerService.isShowingAd)
        #expect(playerService.shouldResumeAfterInterruption)
    }

    @Test("A deduplicated same-video-ID request preserves native playback state")
    func deduplicatedVideoIDRequestPreservesPlaybackState() async {
        let videoId = "same-video"
        let (playerService, webKitManager) = self.makeLoadedPlayer(videoId: videoId)
        _ = webKitManager
        defer { SingletonPlayerWebView.shared.tearDown() }
        let song = Song(
            id: "existing-song",
            title: "Existing Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: videoId
        )
        self.seedPausedPlayback(playerService, song: song)

        await playerService.play(videoId: videoId)

        #expect(playerService.state == .paused)
        #expect(playerService.progress == 42)
        #expect(playerService.currentTimeMs == 42000)
        #expect(playerService.duration == 180)
        #expect(playerService.isShowingAd)
        #expect(playerService.currentTrack?.title == "Existing Song")
        #expect(playerService.shouldResumeAfterInterruption)
    }

    @Test("Distinct queue entries sharing a video ID start a fresh occurrence")
    func distinctSameVideoQueueEntriesStartFreshPlayback() async throws {
        let videoId = "same-video"
        let (playerService, webKitManager) = self.makeLoadedPlayer(videoId: videoId)
        _ = webKitManager
        defer { SingletonPlayerWebView.shared.tearDown() }
        let firstSong = Song(
            id: "first",
            title: "First occurrence",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: videoId
        )
        let secondSong = Song(
            id: "second",
            title: "Second occurrence",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: videoId
        )
        playerService.setQueue(entries: [
            QueueEntry(id: UUID(), song: firstSong),
            QueueEntry(id: UUID(), song: secondSong),
        ])
        playerService.currentIndex = 0
        await playerService.play(song: firstSong)
        let firstOccurrence = try #require(playerService.currentMusicPlaybackOccurrence)
        playerService.progress = 42
        playerService.currentTimeMs = 42000

        await playerService.playFromQueue(at: 1)

        let secondOccurrence = try #require(playerService.currentMusicPlaybackOccurrence)
        #expect(playerService.currentTrack?.id == "second")
        #expect(playerService.currentIndex == 1)
        #expect(playerService.progress == 0)
        #expect(secondOccurrence != firstOccurrence)
        #expect(secondOccurrence.nativeGeneration > firstOccurrence.nativeGeneration)
    }

    @Test("Fresh same-video occurrence forces navigation while an ad is active")
    func sameVideoOccurrenceUsesFullNavigationDuringAd() {
        #expect(SingletonPlayerWebView.freshSameIDPlaybackStrategy(isShowingAd: true)
            == .forceFullPageWhenSameVideoId)
        #expect(SingletonPlayerWebView.freshSameIDPlaybackStrategy(isShowingAd: false)
            == .preferInPlaceWhenSameVideoId)
    }

    @Test("Rapid music toggles follow native command intent before observer catch-up")
    func rapidMusicTogglesAlternateIntent() async {
        let playerService = PlayerService()
        playerService.currentTrack = Song(
            id: "song",
            title: "Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "video"
        )
        playerService.pendingPlayVideoId = "video"
        playerService.state = .paused
        playerService.shouldResumeAfterInterruption = false

        await playerService.playPause()
        #expect(playerService.shouldResumeAfterInterruption)
        #expect(playerService.isAwaitingPlaybackConfirmation)
        await playerService.playPause()

        #expect(!playerService.shouldResumeAfterInterruption)
        #expect(!playerService.isAwaitingPlaybackConfirmation)
    }

    @Test("A settled ready-paused autoplay failure resumes on the first toggle")
    func settledAutoplayFailureResumesOnFirstToggle() async {
        let playerService = PlayerService()
        playerService.currentTrack = Song(
            id: "song",
            title: "Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "video"
        )
        playerService.pendingPlayVideoId = "video"
        playerService.currentWebPlaybackVideoId = { "video" }
        playerService.state = .loading
        playerService.shouldResumeAfterInterruption = true
        playerService.isAwaitingPlaybackConfirmation = true
        playerService.updatePlaybackState(isPlaying: false, progress: 0, duration: 180)

        await playerService.playPause()

        #expect(playerService.shouldResumeAfterInterruption)
        #expect(playerService.isAwaitingPlaybackConfirmation)
    }

    @Test("A ready paused advertisement settles play confirmation")
    func readyPausedAdSettlesConfirmation() async {
        let playerService = PlayerService()
        playerService.currentTrack = Song(
            id: "song",
            title: "Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "video"
        )
        playerService.pendingPlayVideoId = "video"
        playerService.currentWebPlaybackVideoId = { "video" }
        playerService.state = .loading
        playerService.shouldResumeAfterInterruption = true
        playerService.isAwaitingPlaybackConfirmation = true

        playerService.updatePlaybackTransportState(isPlaying: false)
        await playerService.playPause()

        #expect(playerService.shouldResumeAfterInterruption)
        #expect(playerService.isAwaitingPlaybackConfirmation)
    }

    @Test("A late playing sample cannot reverse an explicit music pause")
    func latePlayingSampleDoesNotReversePause() async {
        let playerService = PlayerService()
        playerService.currentTrack = Song(
            id: "song",
            title: "Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "video"
        )
        playerService.pendingPlayVideoId = "video"
        playerService.state = .playing
        playerService.shouldResumeAfterInterruption = true
        await playerService.pause()

        playerService.updatePlaybackState(isPlaying: true, progress: 10, duration: 180)

        #expect(playerService.state == .paused)
        #expect(!playerService.shouldResumeAfterInterruption)
    }

    @Test("Ending music clears an outstanding resume confirmation")
    func endedPlaybackClearsConfirmation() {
        let playerService = PlayerService()
        playerService.isAwaitingPlaybackConfirmation = true
        playerService.shouldResumeAfterInterruption = true

        playerService.markPlaybackEnded()

        #expect(!playerService.isAwaitingPlaybackConfirmation)
        #expect(!playerService.shouldResumeAfterInterruption)
    }

    private func makeLoadedPlayer(videoId: String) -> (PlayerService, WebKitManager) {
        let singleton = SingletonPlayerWebView.shared
        singleton.tearDown()
        let playerService = PlayerService()
        let webKitManager = WebKitManager.makeTestInstance()
        _ = singleton.getWebView(
            webKitManager: webKitManager,
            playerService: playerService
        )
        singleton.currentVideoId = videoId
        return (playerService, webKitManager)
    }

    private func seedPausedPlayback(_ playerService: PlayerService, song: Song) {
        playerService.currentTrack = song
        playerService.pendingPlayVideoId = song.videoId
        playerService.state = .paused
        playerService.shouldResumeAfterInterruption = false
        playerService.progress = 42
        playerService.currentTimeMs = 42000
        playerService.duration = 180
        playerService.isShowingAd = true
    }
}
