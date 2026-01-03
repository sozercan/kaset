import Foundation
import Testing
@testable import Kaset

/// Tests for PlayerService.
@Suite("PlayerService", .serialized, .tags(.service))
@MainActor
struct PlayerServiceTests {
    var playerService: PlayerService

    init() {
        // Reset UserDefaults to ensure clean initial state for tests
        UserDefaults.standard.removeObject(forKey: "playerVolume")
        UserDefaults.standard.removeObject(forKey: "playerVolumeBeforeMute")
        self.playerService = PlayerService()
    }

    // MARK: - Initial State Tests

    @Test("Initial state is idle")
    func initialState() {
        #expect(self.playerService.state == .idle)
        #expect(self.playerService.currentTrack == nil)
        #expect(self.playerService.isPlaying == false)
        #expect(self.playerService.progress == 0)
        #expect(self.playerService.duration == 0)
        #expect(self.playerService.volume == 1.0)
    }

    @Test("isPlaying property")
    func isPlayingProperty() {
        #expect(self.playerService.isPlaying == false)
    }

    // MARK: - PlaybackState Tests

    @Test("PlaybackState equality")
    func playbackStateEquatable() {
        let state1 = PlayerService.PlaybackState.playing
        let state2 = PlayerService.PlaybackState.playing
        #expect(state1 == state2)

        let state3 = PlayerService.PlaybackState.paused
        #expect(state1 != state3)

        let error1 = PlayerService.PlaybackState.error("Test error")
        let error2 = PlayerService.PlaybackState.error("Test error")
        #expect(error1 == error2)

        let error3 = PlayerService.PlaybackState.error("Different error")
        #expect(error1 != error3)
    }

    @Test(
        "PlaybackState isPlaying returns correct value",
        arguments: [
            (PlayerService.PlaybackState.playing, true),
            (PlayerService.PlaybackState.paused, false),
            (PlayerService.PlaybackState.idle, false),
            (PlayerService.PlaybackState.loading, false),
            (PlayerService.PlaybackState.buffering, false),
            (PlayerService.PlaybackState.ended, false),
            (PlayerService.PlaybackState.error("test"), false),
        ]
    )
    func playbackStateIsPlaying(state: PlayerService.PlaybackState, expected: Bool) {
        #expect(state.isPlaying == expected)
    }

    // MARK: - Queue Tests

    @Test("Queue initially empty")
    func queueInitiallyEmpty() {
        #expect(self.playerService.queue.isEmpty)
        #expect(self.playerService.currentIndex == 0)
    }

    @Test("Update playback state to playing")
    func updatePlaybackState() {
        self.playerService.updatePlaybackState(isPlaying: true, progress: 30.0, duration: 180.0)

        #expect(self.playerService.state == .playing)
        #expect(self.playerService.progress == 30.0)
        #expect(self.playerService.duration == 180.0)
        #expect(self.playerService.isPlaying == true)
    }

    @Test("Update playback state to paused")
    func updatePlaybackStatePaused() {
        self.playerService.updatePlaybackState(isPlaying: true, progress: 30.0, duration: 180.0)
        #expect(self.playerService.state == .playing)

        self.playerService.updatePlaybackState(isPlaying: false, progress: 30.0, duration: 180.0)
        #expect(self.playerService.state == .paused)
        #expect(self.playerService.isPlaying == false)
    }

    @Test("Update track metadata")
    func updateTrackMetadata() {
        self.playerService.updateTrackMetadata(
            title: "Test Song",
            artist: "Test Artist",
            thumbnailUrl: "https://example.com/thumb.jpg"
        )

        #expect(self.playerService.currentTrack != nil)
        #expect(self.playerService.currentTrack?.title == "Test Song")
        #expect(self.playerService.currentTrack?.artistsDisplay == "Test Artist")
        #expect(self.playerService.currentTrack?.thumbnailURL?.absoluteString == "https://example.com/thumb.jpg")
    }

    @Test("Update track metadata with empty thumbnail")
    func updateTrackMetadataWithEmptyThumbnail() {
        self.playerService.updateTrackMetadata(
            title: "Test Song",
            artist: "Test Artist",
            thumbnailUrl: ""
        )

        #expect(self.playerService.currentTrack != nil)
        #expect(self.playerService.currentTrack?.title == "Test Song")
        #expect(self.playerService.currentTrack?.thumbnailURL == nil)
    }

    @Test("Confirm playback started")
    func confirmPlaybackStarted() {
        self.playerService.showMiniPlayer = true
        self.playerService.confirmPlaybackStarted()

        #expect(self.playerService.showMiniPlayer == false)
        #expect(self.playerService.state == .playing)
    }

    @Test("Mini player dismissed")
    func miniPlayerDismissed() {
        self.playerService.showMiniPlayer = true
        self.playerService.miniPlayerDismissed()

        #expect(self.playerService.showMiniPlayer == false)
    }

    // MARK: - Shuffle and Repeat Mode Tests

    @Test("Toggle shuffle")
    func toggleShuffle() {
        #expect(self.playerService.shuffleEnabled == false)

        self.playerService.toggleShuffle()
        #expect(self.playerService.shuffleEnabled == true)

        self.playerService.toggleShuffle()
        #expect(self.playerService.shuffleEnabled == false)
    }

    @Test("Cycle repeat mode")
    func cycleRepeatMode() {
        #expect(self.playerService.repeatMode == .off)

        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .all)

        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .one)

        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .off)
    }

    // MARK: - Volume Tests

    @Test("Is muted initially false")
    func isMuted() {
        #expect(self.playerService.isMuted == false)
    }

    @Test("Initial volume is 1.0")
    func initialVolume() {
        #expect(self.playerService.volume == 1.0)
    }

    // MARK: - Queue Tests

    @Test("Play queue sets queue")
    func playQueueSetsQueue() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await playerService.playQueue(songs, startingAt: 0)

        #expect(self.playerService.queue.count == 3)
        #expect(self.playerService.currentIndex == 0)
    }

    @Test("Play queue starting at index")
    func playQueueStartingAtIndex() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await playerService.playQueue(songs, startingAt: 2)

        #expect(self.playerService.currentIndex == 2)
    }

    @Test("Play queue with invalid index clamps to valid range")
    func playQueueWithInvalidIndex() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
        ]

        await playerService.playQueue(songs, startingAt: 10)

        #expect(self.playerService.currentIndex == 0)
    }

    @Test("Play empty queue does nothing")
    func playQueueEmptyDoesNothing() async {
        await self.playerService.playQueue([], startingAt: 0)
        #expect(self.playerService.queue.isEmpty)
    }

    // MARK: - User Interaction Tests

    @Test("hasUserInteractedThisSession initially false")
    func hasUserInteractedThisSessionInitiallyFalse() {
        #expect(self.playerService.hasUserInteractedThisSession == false)
    }

    @Test("confirmPlaybackStarted sets userInteracted")
    func confirmPlaybackStartedSetsUserInteracted() {
        #expect(self.playerService.hasUserInteractedThisSession == false)
        self.playerService.confirmPlaybackStarted()
        #expect(self.playerService.hasUserInteractedThisSession == true)
    }

    // MARK: - Pending Play Video Tests

    @Test("pendingPlayVideoId initially nil")
    func pendingPlayVideoIdInitiallyNil() {
        #expect(self.playerService.pendingPlayVideoId == nil)
    }

    // MARK: - Mini Player State Tests

    @Test("Mini player initially hidden")
    func miniPlayerInitiallyHidden() {
        #expect(self.playerService.showMiniPlayer == false)
    }

    // MARK: - Queue/Lyrics Mutual Exclusivity Tests

    @Test("showQueue initially false")
    func showQueueInitiallyFalse() {
        #expect(self.playerService.showQueue == false)
    }

    @Test("showLyrics initially false")
    func showLyricsInitiallyFalse() {
        #expect(self.playerService.showLyrics == false)
    }

    @Test("Show queue closes lyrics")
    func showQueueClosesLyrics() {
        self.playerService.showLyrics = true
        #expect(self.playerService.showLyrics == true)
        #expect(self.playerService.showQueue == false)

        self.playerService.showQueue = true
        #expect(self.playerService.showQueue == true)
        #expect(self.playerService.showLyrics == false, "Opening queue should close lyrics")
    }

    @Test("Show lyrics closes queue")
    func showLyricsClosesQueue() {
        self.playerService.showQueue = true
        #expect(self.playerService.showQueue == true)
        #expect(self.playerService.showLyrics == false)

        self.playerService.showLyrics = true
        #expect(self.playerService.showLyrics == true)
        #expect(self.playerService.showQueue == false, "Opening lyrics should close queue")
    }

    @Test("Both sidebars can be closed")
    func bothSidebarsCanBeClosed() {
        self.playerService.showQueue = true
        #expect(self.playerService.showQueue == true)

        self.playerService.showQueue = false
        #expect(self.playerService.showQueue == false)
        #expect(self.playerService.showLyrics == false)
    }

    // MARK: - Clear Queue Tests

    @Test("Clear queue with no current track")
    func clearQueueWithNoCurrentTrack() {
        self.playerService.clearQueue()

        #expect(self.playerService.queue.isEmpty)
        #expect(self.playerService.currentIndex == 0)
    }

    @Test("Clear queue keeps current track")
    func clearQueueKeepsCurrentTrack() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await playerService.playQueue(songs, startingAt: 1)

        self.playerService.clearQueue()

        #expect(self.playerService.queue.count == 1)
        #expect(self.playerService.queue.first?.videoId == "v2")
        #expect(self.playerService.currentIndex == 0)
    }

    // MARK: - Play From Queue Tests

    @Test("Play from queue valid index")
    func playFromQueueValidIndex() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await playerService.playQueue(songs, startingAt: 0)
        await self.playerService.playFromQueue(at: 2)

        #expect(self.playerService.currentIndex == 2)
        #expect(self.playerService.currentTrack?.videoId == "v3")
    }

    @Test("Play from queue invalid index does nothing")
    func playFromQueueInvalidIndexDoesNothing() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
        ]

        await playerService.playQueue(songs, startingAt: 0)
        await self.playerService.playFromQueue(at: 5)

        #expect(self.playerService.currentIndex == 0)
    }

    @Test("Play from queue negative index does nothing")
    func playFromQueueNegativeIndexDoesNothing() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
        ]

        await playerService.playQueue(songs, startingAt: 0)
        await self.playerService.playFromQueue(at: -1)

        #expect(self.playerService.currentIndex == 0)
    }

    // MARK: - Play With Radio Tests

    @Test("Play with radio starts playback immediately")
    func playWithRadioStartsPlaybackImmediately() async {
        let song = Song(
            id: "radio-seed",
            title: "Seed Song",
            artists: [Artist(id: "artist-1", name: "Artist 1")],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "radio-seed-video"
        )

        await playerService.playWithRadio(song: song)

        #expect(self.playerService.currentTrack?.videoId == "radio-seed-video")
        #expect(self.playerService.currentTrack?.title == "Seed Song")
        #expect(self.playerService.queue.isEmpty == false)
    }

    @Test("Play with radio sets queue with seed song")
    func playWithRadioSetsQueueWithSeedSong() async {
        let song = Song(
            id: "seed",
            title: "Seed Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "seed-video"
        )

        await playerService.playWithRadio(song: song)

        #expect(self.playerService.queue.count == 1)
        #expect(self.playerService.queue.first?.videoId == "seed-video")
        #expect(self.playerService.currentIndex == 0)
    }

    @Test("Play with radio fetches radio queue")
    func playWithRadioFetchesRadioQueue() async {
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

        await playerService.playWithRadio(song: song)

        #expect(mockClient.getRadioQueueCalled == true)
        #expect(mockClient.getRadioQueueVideoIds.first == "seed-video")
        #expect(self.playerService.queue.count == 4)
        #expect(self.playerService.queue.first?.videoId == "seed-video", "Seed song should be at front of queue")
        #expect(self.playerService.currentIndex == 0)
    }

    @Test("Play with radio keeps seed song at front when not in radio")
    func playWithRadioKeepsSeedSongAtFrontWhenNotInRadio() async {
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

        await playerService.playWithRadio(song: song)

        #expect(self.playerService.queue.count == 3)
        #expect(self.playerService.queue[0].videoId == "seed-video", "Seed song should be first")
        #expect(self.playerService.queue[1].videoId == "radio-video-1")
        #expect(self.playerService.queue[2].videoId == "radio-video-2")
    }

    @Test("Play with radio reorders seed song to front")
    func playWithRadioReordersSeedSongToFront() async {
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

        await playerService.playWithRadio(song: song)

        #expect(self.playerService.queue.count == 3)
        #expect(self.playerService.queue[0].videoId == "seed-video", "Seed song should be first")
        #expect(self.playerService.queue[1].videoId == "radio-video-1")
        #expect(self.playerService.queue[2].videoId == "radio-video-2")
    }

    @Test("Play with radio handles empty radio queue")
    func playWithRadioHandlesEmptyRadioQueue() async {
        let mockClient = MockYTMusicClient()
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

        await playerService.playWithRadio(song: song)

        #expect(self.playerService.queue.count == 1)
        #expect(self.playerService.queue.first?.videoId == "lonely-video")
    }
}
