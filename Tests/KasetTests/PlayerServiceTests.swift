import XCTest
@testable import Kaset

/// Tests for PlayerService.
@MainActor
final class PlayerServiceTests: XCTestCase {
    var playerService: PlayerService!

    override func setUp() async throws {
        self.playerService = PlayerService()
    }

    override func tearDown() async throws {
        self.playerService = nil
    }

    func testInitialState() {
        XCTAssertEqual(self.playerService.state, .idle)
        XCTAssertNil(self.playerService.currentTrack)
        XCTAssertFalse(self.playerService.isPlaying)
        XCTAssertEqual(self.playerService.progress, 0)
        XCTAssertEqual(self.playerService.duration, 0)
        XCTAssertEqual(self.playerService.volume, 1.0)
    }

    func testIsPlayingProperty() {
        XCTAssertFalse(self.playerService.isPlaying)
        // Note: We can't easily test state changes without mocking the WebView
    }

    func testPlaybackStateEquatable() {
        let state1 = PlayerService.PlaybackState.playing
        let state2 = PlayerService.PlaybackState.playing
        XCTAssertEqual(state1, state2)

        let state3 = PlayerService.PlaybackState.paused
        XCTAssertNotEqual(state1, state3)

        let error1 = PlayerService.PlaybackState.error("Test error")
        let error2 = PlayerService.PlaybackState.error("Test error")
        XCTAssertEqual(error1, error2)

        let error3 = PlayerService.PlaybackState.error("Different error")
        XCTAssertNotEqual(error1, error3)
    }

    func testPlaybackStateIsPlaying() {
        XCTAssertTrue(PlayerService.PlaybackState.playing.isPlaying)
        XCTAssertFalse(PlayerService.PlaybackState.paused.isPlaying)
        XCTAssertFalse(PlayerService.PlaybackState.idle.isPlaying)
        XCTAssertFalse(PlayerService.PlaybackState.loading.isPlaying)
        XCTAssertFalse(PlayerService.PlaybackState.buffering.isPlaying)
        XCTAssertFalse(PlayerService.PlaybackState.ended.isPlaying)
        XCTAssertFalse(PlayerService.PlaybackState.error("test").isPlaying)
    }

    func testQueueInitiallyEmpty() {
        XCTAssertTrue(self.playerService.queue.isEmpty)
        XCTAssertEqual(self.playerService.currentIndex, 0)
    }

    func testUpdatePlaybackState() {
        self.playerService.updatePlaybackState(isPlaying: true, progress: 30.0, duration: 180.0)

        XCTAssertEqual(self.playerService.state, .playing)
        XCTAssertEqual(self.playerService.progress, 30.0)
        XCTAssertEqual(self.playerService.duration, 180.0)
        XCTAssertTrue(self.playerService.isPlaying)
    }

    func testUpdatePlaybackStatePaused() {
        // First set to playing
        self.playerService.updatePlaybackState(isPlaying: true, progress: 30.0, duration: 180.0)
        XCTAssertEqual(self.playerService.state, .playing)

        // Then pause
        self.playerService.updatePlaybackState(isPlaying: false, progress: 30.0, duration: 180.0)
        XCTAssertEqual(self.playerService.state, .paused)
        XCTAssertFalse(self.playerService.isPlaying)
    }

    func testUpdateTrackMetadata() {
        self.playerService.updateTrackMetadata(
            title: "Test Song",
            artist: "Test Artist",
            thumbnailUrl: "https://example.com/thumb.jpg"
        )

        XCTAssertNotNil(self.playerService.currentTrack)
        XCTAssertEqual(self.playerService.currentTrack?.title, "Test Song")
        XCTAssertEqual(self.playerService.currentTrack?.artistsDisplay, "Test Artist")
        XCTAssertEqual(self.playerService.currentTrack?.thumbnailURL?.absoluteString, "https://example.com/thumb.jpg")
    }

    func testUpdateTrackMetadataWithEmptyThumbnail() {
        self.playerService.updateTrackMetadata(
            title: "Test Song",
            artist: "Test Artist",
            thumbnailUrl: ""
        )

        XCTAssertNotNil(self.playerService.currentTrack)
        XCTAssertEqual(self.playerService.currentTrack?.title, "Test Song")
        XCTAssertNil(self.playerService.currentTrack?.thumbnailURL)
    }

    func testConfirmPlaybackStarted() {
        self.playerService.showMiniPlayer = true
        self.playerService.confirmPlaybackStarted()

        XCTAssertFalse(self.playerService.showMiniPlayer)
        XCTAssertEqual(self.playerService.state, .playing)
    }

    func testMiniPlayerDismissed() {
        self.playerService.showMiniPlayer = true
        self.playerService.miniPlayerDismissed()

        XCTAssertFalse(self.playerService.showMiniPlayer)
    }

    // MARK: - Shuffle and Repeat Mode Tests

    func testToggleShuffle() {
        XCTAssertFalse(self.playerService.shuffleEnabled)

        self.playerService.toggleShuffle()
        XCTAssertTrue(self.playerService.shuffleEnabled)

        self.playerService.toggleShuffle()
        XCTAssertFalse(self.playerService.shuffleEnabled)
    }

    func testCycleRepeatMode() {
        XCTAssertEqual(self.playerService.repeatMode, .off)

        self.playerService.cycleRepeatMode()
        XCTAssertEqual(self.playerService.repeatMode, .all)

        self.playerService.cycleRepeatMode()
        XCTAssertEqual(self.playerService.repeatMode, .one)

        self.playerService.cycleRepeatMode()
        XCTAssertEqual(self.playerService.repeatMode, .off)
    }

    // MARK: - Volume Tests

    func testIsMuted() {
        XCTAssertFalse(self.playerService.isMuted)
    }

    func testInitialVolume() {
        XCTAssertEqual(self.playerService.volume, 1.0)
    }

    // MARK: - Queue Tests

    func testPlayQueueSetsQueue() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await playerService.playQueue(songs, startingAt: 0)

        XCTAssertEqual(self.playerService.queue.count, 3)
        XCTAssertEqual(self.playerService.currentIndex, 0)
    }

    func testPlayQueueStartingAtIndex() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await playerService.playQueue(songs, startingAt: 2)

        XCTAssertEqual(self.playerService.currentIndex, 2)
    }

    func testPlayQueueWithInvalidIndex() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
        ]

        await playerService.playQueue(songs, startingAt: 10)

        // Should clamp to valid range
        XCTAssertEqual(self.playerService.currentIndex, 0)
    }

    func testPlayQueueEmptyDoesNothing() async {
        await self.playerService.playQueue([], startingAt: 0)

        XCTAssertTrue(self.playerService.queue.isEmpty)
    }

    // MARK: - PlaybackState State Tests

    func testAllPlaybackStates() {
        let states: [PlayerService.PlaybackState] = [
            .idle,
            .loading,
            .playing,
            .paused,
            .buffering,
            .ended,
            .error("test error"),
        ]

        // Only playing should return true for isPlaying
        for state in states {
            if state == .playing {
                XCTAssertTrue(state.isPlaying)
            } else {
                XCTAssertFalse(state.isPlaying)
            }
        }
    }

    func testPlaybackStateErrorEquality() {
        let error1 = PlayerService.PlaybackState.error("same message")
        let error2 = PlayerService.PlaybackState.error("same message")
        let error3 = PlayerService.PlaybackState.error("different message")

        XCTAssertEqual(error1, error2)
        XCTAssertNotEqual(error1, error3)
    }

    // MARK: - hasUserInteractedThisSession Tests

    func testHasUserInteractedThisSessionInitiallyFalse() {
        XCTAssertFalse(self.playerService.hasUserInteractedThisSession)
    }

    func testConfirmPlaybackStartedSetsUserInteracted() {
        XCTAssertFalse(self.playerService.hasUserInteractedThisSession)

        self.playerService.confirmPlaybackStarted()

        XCTAssertTrue(self.playerService.hasUserInteractedThisSession)
    }

    // MARK: - Pending Play Video Tests

    func testPendingPlayVideoIdInitiallyNil() {
        XCTAssertNil(self.playerService.pendingPlayVideoId)
    }

    // MARK: - Mini Player State Tests

    func testMiniPlayerInitiallyHidden() {
        XCTAssertFalse(self.playerService.showMiniPlayer)
    }

    func testMiniPlayerDismissedResetsLoadingState() {
        // First set state to loading
        self.playerService.updatePlaybackState(isPlaying: false, progress: 0, duration: 0)

        // Simulate being in loading state
        // Note: We're testing the idle transition when already idle, which should stay idle
        self.playerService.showMiniPlayer = true
        self.playerService.miniPlayerDismissed()

        XCTAssertFalse(self.playerService.showMiniPlayer)
    }

    // MARK: - Queue/Lyrics Mutual Exclusivity Tests

    func testShowQueueInitiallyFalse() {
        XCTAssertFalse(self.playerService.showQueue)
    }

    func testShowLyricsInitiallyFalse() {
        XCTAssertFalse(self.playerService.showLyrics)
    }

    func testShowQueueClosesLyrics() {
        // First show lyrics
        self.playerService.showLyrics = true
        XCTAssertTrue(self.playerService.showLyrics)
        XCTAssertFalse(self.playerService.showQueue)

        // Opening queue should close lyrics
        self.playerService.showQueue = true
        XCTAssertTrue(self.playerService.showQueue)
        XCTAssertFalse(self.playerService.showLyrics, "Opening queue should close lyrics")
    }

    func testShowLyricsClosesQueue() {
        // First show queue
        self.playerService.showQueue = true
        XCTAssertTrue(self.playerService.showQueue)
        XCTAssertFalse(self.playerService.showLyrics)

        // Opening lyrics should close queue
        self.playerService.showLyrics = true
        XCTAssertTrue(self.playerService.showLyrics)
        XCTAssertFalse(self.playerService.showQueue, "Opening lyrics should close queue")
    }

    func testBothSidebarsCanBeClosed() {
        // Show queue then close it
        self.playerService.showQueue = true
        XCTAssertTrue(self.playerService.showQueue)

        self.playerService.showQueue = false
        XCTAssertFalse(self.playerService.showQueue)
        XCTAssertFalse(self.playerService.showLyrics)
    }

    // MARK: - Clear Queue Tests

    func testClearQueueWithNoCurrentTrack() {
        // Add some songs to queue
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        Task {
            await self.playerService.playQueue(songs, startingAt: 0)
        }

        // Clear with no current track
        self.playerService.clearQueue()

        XCTAssertTrue(self.playerService.queue.isEmpty)
        XCTAssertEqual(self.playerService.currentIndex, 0)
    }

    func testClearQueueKeepsCurrentTrack() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await self.playerService.playQueue(songs, startingAt: 1)

        // Clear queue should keep only the current track
        self.playerService.clearQueue()

        XCTAssertEqual(self.playerService.queue.count, 1)
        XCTAssertEqual(self.playerService.queue.first?.videoId, "v2")
        XCTAssertEqual(self.playerService.currentIndex, 0)
    }

    // MARK: - Play From Queue Tests

    func testPlayFromQueueValidIndex() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)

        await self.playerService.playFromQueue(at: 2)

        XCTAssertEqual(self.playerService.currentIndex, 2)
        XCTAssertEqual(self.playerService.currentTrack?.videoId, "v3")
    }

    func testPlayFromQueueInvalidIndexDoesNothing() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)

        // Try to play from invalid index
        await self.playerService.playFromQueue(at: 5)

        // Should stay at original index
        XCTAssertEqual(self.playerService.currentIndex, 0)
    }

    func testPlayFromQueueNegativeIndexDoesNothing() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)

        // Try to play from negative index
        await self.playerService.playFromQueue(at: -1)

        // Should stay at original index
        XCTAssertEqual(self.playerService.currentIndex, 0)
    }

    // MARK: - Play With Radio Tests

    func testPlayWithRadioStartsPlaybackImmediately() async {
        let song = Song(
            id: "radio-seed",
            title: "Seed Song",
            artists: [Artist(id: "artist-1", name: "Artist 1")],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "radio-seed-video"
        )

        await self.playerService.playWithRadio(song: song)

        // Playback should start immediately with the seed song
        XCTAssertEqual(self.playerService.currentTrack?.videoId, "radio-seed-video")
        XCTAssertEqual(self.playerService.currentTrack?.title, "Seed Song")
        // Queue should at minimum have the seed song
        XCTAssertFalse(self.playerService.queue.isEmpty)
    }

    func testPlayWithRadioSetsQueueWithSeedSong() async {
        let song = Song(
            id: "seed",
            title: "Seed Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "seed-video"
        )

        // Without a YTMusicClient, the queue should just have the seed song
        await self.playerService.playWithRadio(song: song)

        XCTAssertEqual(self.playerService.queue.count, 1)
        XCTAssertEqual(self.playerService.queue.first?.videoId, "seed-video")
        XCTAssertEqual(self.playerService.currentIndex, 0)
    }

    func testPlayWithRadioFetchesRadioQueue() async {
        // Set up mock client with radio queue
        let mockClient = MockYTMusicClient()
        let radioSongs = [
            Song(id: "radio-1", title: "Radio Song 1", artists: [], videoId: "radio-video-1"),
            Song(id: "radio-2", title: "Radio Song 2", artists: [], videoId: "radio-video-2"),
            Song(id: "radio-3", title: "Radio Song 3", artists: [], videoId: "radio-video-3"),
        ]
        mockClient.radioQueueSongs["seed-video"] = radioSongs
        self.playerService.setYTMusicClient(mockClient)

        let song = Song(
            id: "seed",
            title: "Seed Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "seed-video"
        )

        await self.playerService.playWithRadio(song: song)

        // Verify radio queue was fetched
        XCTAssertTrue(mockClient.getRadioQueueCalled)
        XCTAssertEqual(mockClient.getRadioQueueVideoIds.first, "seed-video")

        // Queue should have seed song at front plus radio songs
        XCTAssertEqual(self.playerService.queue.count, 4)
        XCTAssertEqual(self.playerService.queue.first?.videoId, "seed-video", "Seed song should be at front of queue")
        XCTAssertEqual(self.playerService.currentIndex, 0)
    }

    func testPlayWithRadioKeepsSeedSongAtFrontWhenNotInRadio() async {
        // Set up mock client with radio queue that doesn't include the seed song
        let mockClient = MockYTMusicClient()
        let radioSongs = [
            Song(id: "radio-1", title: "Radio Song 1", artists: [], videoId: "radio-video-1"),
            Song(id: "radio-2", title: "Radio Song 2", artists: [], videoId: "radio-video-2"),
        ]
        mockClient.radioQueueSongs["seed-video"] = radioSongs
        self.playerService.setYTMusicClient(mockClient)

        let song = Song(
            id: "seed",
            title: "Seed Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "seed-video"
        )

        await self.playerService.playWithRadio(song: song)

        // Queue should have seed song prepended to radio songs
        XCTAssertEqual(self.playerService.queue.count, 3)
        XCTAssertEqual(self.playerService.queue[0].videoId, "seed-video", "Seed song should be first")
        XCTAssertEqual(self.playerService.queue[1].videoId, "radio-video-1")
        XCTAssertEqual(self.playerService.queue[2].videoId, "radio-video-2")
    }

    func testPlayWithRadioReordersSeedSongToFront() async {
        // Set up mock client with radio queue that has seed song in the middle
        let mockClient = MockYTMusicClient()
        let radioSongs = [
            Song(id: "radio-1", title: "Radio Song 1", artists: [], videoId: "radio-video-1"),
            Song(id: "seed", title: "Seed Song", artists: [], videoId: "seed-video"),
            Song(id: "radio-2", title: "Radio Song 2", artists: [], videoId: "radio-video-2"),
        ]
        mockClient.radioQueueSongs["seed-video"] = radioSongs
        self.playerService.setYTMusicClient(mockClient)

        let song = Song(
            id: "seed",
            title: "Seed Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "seed-video"
        )

        await self.playerService.playWithRadio(song: song)

        // Queue should have seed song moved to front
        XCTAssertEqual(self.playerService.queue.count, 3)
        XCTAssertEqual(self.playerService.queue[0].videoId, "seed-video", "Seed song should be first")
        // Other songs should follow (excluding the duplicate seed song)
        XCTAssertEqual(self.playerService.queue[1].videoId, "radio-video-1")
        XCTAssertEqual(self.playerService.queue[2].videoId, "radio-video-2")
    }

    func testPlayWithRadioHandlesEmptyRadioQueue() async {
        let mockClient = MockYTMusicClient()
        // Don't set any radio songs - simulates empty response
        self.playerService.setYTMusicClient(mockClient)

        let song = Song(
            id: "lonely",
            title: "Lonely Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "lonely-video"
        )

        await self.playerService.playWithRadio(song: song)

        // Queue should still have the original seed song
        XCTAssertEqual(self.playerService.queue.count, 1)
        XCTAssertEqual(self.playerService.queue.first?.videoId, "lonely-video")
    }
}
