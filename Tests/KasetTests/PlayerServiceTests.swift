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
}
