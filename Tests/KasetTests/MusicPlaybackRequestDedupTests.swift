import Foundation
import Testing
@testable import Kaset

// MARK: - MusicPlaybackRequestDedupTests

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

    @Test("A same-video direct request supersedes a different deferred restored load")
    func sameVideoDirectRequestSupersedesStalePendingRestore() async {
        let requestedVideoID = "visible-video"
        let staleVideoID = "stale-restored-video"
        let (playerService, webKitManager) = self.makeLoadedPlayer(videoId: requestedVideoID)
        _ = webKitManager
        defer { SingletonPlayerWebView.shared.tearDown() }
        let mockClient = MockYTMusicClient()
        playerService.setYTMusicClient(mockClient)
        mockClient.songResponses[requestedVideoID] = Song(
            id: requestedVideoID,
            title: "Visible Metadata",
            artists: [Artist(id: "visible-artist", name: "Visible Artist")],
            videoId: requestedVideoID
        )
        let staleSong = Song(
            id: staleVideoID,
            title: "Stale Restored Song",
            artists: [],
            duration: 180,
            videoId: staleVideoID
        )
        playerService.applyRestoredPlaybackSession(
            queue: [staleSong],
            currentIndex: 0,
            progress: 60,
            duration: 180
        )
        #expect(playerService.isPendingRestoredLoadDeferred)
        #expect(playerService.pendingPlayVideoId == staleVideoID)

        await playerService.play(videoId: requestedVideoID)

        #expect(playerService.pendingPlayVideoId == requestedVideoID)
        #expect(playerService.currentTrack?.videoId == requestedVideoID)
        #expect(playerService.currentTrack?.title == "Visible Metadata")
        #expect(!playerService.isPendingRestoredLoadDeferred)
        #expect(playerService.pendingRestoredSeek == nil)
        #expect(SingletonPlayerWebView.shared.currentVideoId == requestedVideoID)
        #expect(mockClient.getSongVideoIds == [requestedVideoID])
    }

    @Test("A direct deduplicated video request detaches ownership under a fresh occurrence")
    func deduplicatedDirectVideoRequestDetachesQueueOwnership() async throws {
        let first = Song(
            id: "direct-same-first",
            title: "Direct Same First",
            artists: [],
            duration: 180,
            videoId: "direct-same-video"
        )
        let second = Song(
            id: "direct-same-second",
            title: "Direct Same Second",
            artists: [],
            duration: 180,
            videoId: "direct-same-next"
        )
        let (playerService, webKitManager) = self.makeLoadedPlayer(videoId: first.videoId)
        _ = webKitManager
        defer { SingletonPlayerWebView.shared.tearDown() }
        let firstEntryID = UUID()
        playerService.setQueue(entries: [
            QueueEntry(id: firstEntryID, song: first),
            QueueEntry(id: UUID(), song: second),
        ])
        playerService.currentIndex = 0
        self.seedPausedPlayback(playerService, song: first)
        playerService.isShowingAd = false
        playerService.activePlaybackQueueEntryID = firstEntryID
        let occurrence = playerService.beginNativeMusicPlaybackOccurrence(videoId: first.videoId)

        await playerService.play(videoId: first.videoId)

        let detachedOccurrence = try #require(playerService.currentMusicPlaybackOccurrence)
        #expect(playerService.activePlaybackQueueEntryID == nil)
        #expect(detachedOccurrence.nativeGeneration > occurrence.nativeGeneration)
        #expect(playerService.progress == 42)
        #expect(playerService.currentIndex == 0)

        await playerService.handleTrackEnded(
            observedVideoId: first.videoId,
            playbackOccurrence: occurrence
        )

        #expect(playerService.currentIndex == 0)
        #expect(playerService.currentTrack?.videoId == first.videoId)
        #expect(playerService.state == .paused)

        await playerService.handleTrackEnded(
            observedVideoId: first.videoId,
            playbackOccurrence: detachedOccurrence
        )

        #expect(playerService.state == .ended)
    }

    @Test("Direct same-video detachment replaces queue-owned metadata work")
    func directSameVideoDetachmentReplacesQueueOwnedMetadataWork() async {
        let videoID = "direct-metadata-handoff"
        let (playerService, webKitManager) = self.makeLoadedPlayer(videoId: videoID)
        _ = webKitManager
        defer { SingletonPlayerWebView.shared.tearDown() }
        let mockClient = MockYTMusicClient()
        playerService.setYTMusicClient(mockClient)
        let incomplete = Song(
            id: videoID,
            title: "Loading...",
            artists: [],
            videoId: videoID
        )
        let entryID = UUID()
        playerService.setQueue(entries: [QueueEntry(id: entryID, song: incomplete)])
        playerService.currentIndex = 0
        playerService.currentTrack = incomplete
        playerService.pendingPlayVideoId = videoID
        playerService.activePlaybackQueueEntryID = entryID
        playerService.state = .paused
        playerService.beginNativeMusicPlaybackOccurrence(videoId: videoID)
        let authoritativeTokens = FeedbackTokens(add: "detached-add", remove: "detached-remove")
        mockClient.songResponses[videoID] = Song(
            id: videoID,
            title: "Detached Metadata",
            artists: [Artist(id: "artist", name: "Artist")],
            videoId: videoID,
            feedbackTokens: authoritativeTokens
        )
        let firstRequestStarted = AsyncGate()
        let releaseFirstRequest = AsyncGate()
        let requestCounter = PlaybackRequestCounter()
        mockClient.beforeGetSongReturn = { _ in
            if await requestCounter.increment() == 1 {
                await firstRequestStarted.open()
                await releaseFirstRequest.wait()
            }
        }
        let queuedFetch = Task { @MainActor in
            await playerService.fetchSongMetadata(
                videoId: videoID,
                queueOwner: .entry(entryID)
            )
        }
        await firstRequestStarted.wait()

        await playerService.play(videoId: videoID)

        #expect(mockClient.getSongVideoIds == [videoID, videoID])
        #expect(playerService.activePlaybackQueueEntryID == nil)
        #expect(playerService.currentTrack?.title == "Detached Metadata")
        #expect(playerService.currentTrackFeedbackTokens == authoritativeTokens)
        #expect(playerService.queue[0].title == "Loading...")
        #expect(playerService.queue[0].feedbackTokens == authoritativeTokens)

        await releaseFirstRequest.open()
        await queuedFetch.value
        #expect(playerService.currentTrack?.title == "Detached Metadata")
        #expect(playerService.queue[0].title == "Loading...")
    }

    @Test("Direct same-video playback clears artist episode semantics")
    func directSameVideoPlaybackClearsArtistEpisodeSemantics() async throws {
        let videoID = "direct-episode-handoff"
        let (playerService, webKitManager) = self.makeLoadedPlayer(videoId: videoID)
        _ = webKitManager
        defer { SingletonPlayerWebView.shared.tearDown() }
        let song = Song(
            id: videoID,
            title: "Episode Representative",
            artists: [],
            duration: 180,
            videoId: videoID,
            feedbackTokens: FeedbackTokens(add: nil, remove: nil)
        )
        self.seedPausedPlayback(playerService, song: song)
        playerService.isShowingAd = false
        playerService.currentEpisode = ArtistEpisode(
            videoId: videoID,
            title: "Live Episode",
            isLive: true
        )
        let occurrence = playerService.beginNativeMusicPlaybackOccurrence(videoId: videoID)

        await playerService.play(videoId: videoID)

        let detachedOccurrence = try #require(playerService.currentMusicPlaybackOccurrence)
        #expect(playerService.currentEpisode == nil)
        #expect(!playerService.isCurrentItemLive)
        #expect(detachedOccurrence.nativeGeneration > occurrence.nativeGeneration)
        #expect(playerService.progress == 42)
        #expect(playerService.duration == 180)
    }

    @Test("Distinct queue entry IDs for the same song start fresh, while reselecting one entry deduplicates")
    func exactSameSongQueueEntriesUseLogicalEntryIdentity() async throws {
        let videoId = "same-video"
        let singleton = SingletonPlayerWebView.shared
        singleton.tearDown()
        singleton.currentVideoId = nil
        defer {
            singleton.tearDown()
            singleton.currentVideoId = nil
        }
        let playerService = PlayerService()
        let song = Song(
            id: "same-song",
            title: "Same Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: videoId
        )
        let firstEntryID = UUID()
        let secondEntryID = UUID()
        playerService.setQueue(entries: [
            QueueEntry(id: firstEntryID, song: song),
            QueueEntry(id: secondEntryID, song: song),
        ])

        await playerService.playFromQueue(at: 0)
        let firstOccurrence = try #require(playerService.currentMusicPlaybackOccurrence)
        #expect(playerService.activePlaybackQueueEntryID == firstEntryID)
        playerService.progress = 42
        playerService.currentTimeMs = 42000

        await playerService.playFromQueue(at: 1)
        let secondOccurrence = try #require(playerService.currentMusicPlaybackOccurrence)
        #expect(playerService.currentTrack == song)
        #expect(playerService.currentIndex == 1)
        #expect(playerService.activePlaybackQueueEntryID == secondEntryID)
        #expect(playerService.progress == 0)
        #expect(secondOccurrence.nativeGeneration > firstOccurrence.nativeGeneration)

        playerService.progress = 17
        playerService.currentTimeMs = 17000
        await playerService.playFromQueue(at: 1)

        let reselectedOccurrence = try #require(playerService.currentMusicPlaybackOccurrence)
        #expect(reselectedOccurrence == secondOccurrence)
        #expect(playerService.activePlaybackQueueEntryID == secondEntryID)
        #expect(playerService.progress == 17)
        #expect(playerService.currentTimeMs == 17000)
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
        let likeStatusManager = SongLikeStatusManager()
        likeStatusManager.setActiveAccountID(nil)
        playerService.setSongLikeStatusManager(likeStatusManager)
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

// MARK: - PlaybackRequestCounter

private actor PlaybackRequestCounter {
    private var count = 0

    func increment() -> Int {
        self.count += 1
        return self.count
    }
}
