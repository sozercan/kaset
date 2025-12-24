import Foundation
import Testing
@testable import Kaset

/// Tests for PlayerService.
@Suite(.serialized)
@MainActor
struct PlayerServiceTests {
    var playerService: PlayerService

    init() {
        self.playerService = PlayerService()
    }

    // MARK: - Initial State Tests

    @Test("Initial state is idle")
    func initialState() {
        #expect(playerService.state == .idle)
        #expect(playerService.currentTrack == nil)
        #expect(playerService.isPlaying == false)
        #expect(playerService.progress == 0)
        #expect(playerService.duration == 0)
        #expect(playerService.volume == 1.0)
    }

    @Test("isPlaying property")
    func isPlayingProperty() {
        #expect(playerService.isPlaying == false)
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
        #expect(playerService.queue.isEmpty)
        #expect(playerService.currentIndex == 0)
    }

    @Test("Update playback state to playing")
    func updatePlaybackState() {
        playerService.updatePlaybackState(isPlaying: true, progress: 30.0, duration: 180.0)

        #expect(playerService.state == .playing)
        #expect(playerService.progress == 30.0)
        #expect(playerService.duration == 180.0)
        #expect(playerService.isPlaying == true)
    }

    @Test("Update playback state to paused")
    func updatePlaybackStatePaused() {
        playerService.updatePlaybackState(isPlaying: true, progress: 30.0, duration: 180.0)
        #expect(playerService.state == .playing)

        playerService.updatePlaybackState(isPlaying: false, progress: 30.0, duration: 180.0)
        #expect(playerService.state == .paused)
        #expect(playerService.isPlaying == false)
    }

    @Test("Update track metadata")
    func updateTrackMetadata() {
        playerService.updateTrackMetadata(
            title: "Test Song",
            artist: "Test Artist",
            thumbnailUrl: "https://example.com/thumb.jpg"
        )

        #expect(playerService.currentTrack != nil)
        #expect(playerService.currentTrack?.title == "Test Song")
        #expect(playerService.currentTrack?.artistsDisplay == "Test Artist")
        #expect(playerService.currentTrack?.thumbnailURL?.absoluteString == "https://example.com/thumb.jpg")
    }

    @Test("Update track metadata with empty thumbnail")
    func updateTrackMetadataWithEmptyThumbnail() {
        playerService.updateTrackMetadata(
            title: "Test Song",
            artist: "Test Artist",
            thumbnailUrl: ""
        )

        #expect(playerService.currentTrack != nil)
        #expect(playerService.currentTrack?.title == "Test Song")
        #expect(playerService.currentTrack?.thumbnailURL == nil)
    }

    @Test("Confirm playback started")
    func confirmPlaybackStarted() {
        playerService.showMiniPlayer = true
        playerService.confirmPlaybackStarted()

        #expect(playerService.showMiniPlayer == false)
        #expect(playerService.state == .playing)
    }

    @Test("Mini player dismissed")
    func miniPlayerDismissed() {
        playerService.showMiniPlayer = true
        playerService.miniPlayerDismissed()

        #expect(playerService.showMiniPlayer == false)
    }

    // MARK: - Shuffle and Repeat Mode Tests

    @Test("Toggle shuffle")
    func toggleShuffle() {
        #expect(playerService.shuffleEnabled == false)

        playerService.toggleShuffle()
        #expect(playerService.shuffleEnabled == true)

        playerService.toggleShuffle()
        #expect(playerService.shuffleEnabled == false)
    }

    @Test("Cycle repeat mode")
    func cycleRepeatMode() {
        #expect(playerService.repeatMode == .off)

        playerService.cycleRepeatMode()
        #expect(playerService.repeatMode == .all)

        playerService.cycleRepeatMode()
        #expect(playerService.repeatMode == .one)

        playerService.cycleRepeatMode()
        #expect(playerService.repeatMode == .off)
    }

    // MARK: - Volume Tests

    @Test("Is muted initially false")
    func isMuted() {
        #expect(playerService.isMuted == false)
    }

    @Test("Initial volume is 1.0")
    func initialVolume() {
        #expect(playerService.volume == 1.0)
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

        #expect(playerService.queue.count == 3)
        #expect(playerService.currentIndex == 0)
    }

    @Test("Play queue starting at index")
    func playQueueStartingAtIndex() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await playerService.playQueue(songs, startingAt: 2)

        #expect(playerService.currentIndex == 2)
    }

    @Test("Play queue with invalid index clamps to valid range")
    func playQueueWithInvalidIndex() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
        ]

        await playerService.playQueue(songs, startingAt: 10)

        #expect(playerService.currentIndex == 0)
    }

    @Test("Play empty queue does nothing")
    func playQueueEmptyDoesNothing() async {
        await playerService.playQueue([], startingAt: 0)
        #expect(playerService.queue.isEmpty)
    }

    // MARK: - User Interaction Tests

    @Test("hasUserInteractedThisSession initially false")
    func hasUserInteractedThisSessionInitiallyFalse() {
        #expect(playerService.hasUserInteractedThisSession == false)
    }

    @Test("confirmPlaybackStarted sets userInteracted")
    func confirmPlaybackStartedSetsUserInteracted() {
        #expect(playerService.hasUserInteractedThisSession == false)
        playerService.confirmPlaybackStarted()
        #expect(playerService.hasUserInteractedThisSession == true)
    }

    // MARK: - Pending Play Video Tests

    @Test("pendingPlayVideoId initially nil")
    func pendingPlayVideoIdInitiallyNil() {
        #expect(playerService.pendingPlayVideoId == nil)
    }

    // MARK: - Mini Player State Tests

    @Test("Mini player initially hidden")
    func miniPlayerInitiallyHidden() {
        #expect(playerService.showMiniPlayer == false)
    }

    // MARK: - Queue/Lyrics Mutual Exclusivity Tests

    @Test("showQueue initially false")
    func showQueueInitiallyFalse() {
        #expect(playerService.showQueue == false)
    }

    @Test("showLyrics initially false")
    func showLyricsInitiallyFalse() {
        #expect(playerService.showLyrics == false)
    }

    @Test("Show queue closes lyrics")
    func showQueueClosesLyrics() {
        playerService.showLyrics = true
        #expect(playerService.showLyrics == true)
        #expect(playerService.showQueue == false)

        playerService.showQueue = true
        #expect(playerService.showQueue == true)
        #expect(playerService.showLyrics == false, "Opening queue should close lyrics")
    }

    @Test("Show lyrics closes queue")
    func showLyricsClosesQueue() {
        playerService.showQueue = true
        #expect(playerService.showQueue == true)
        #expect(playerService.showLyrics == false)

        playerService.showLyrics = true
        #expect(playerService.showLyrics == true)
        #expect(playerService.showQueue == false, "Opening lyrics should close queue")
    }

    @Test("Both sidebars can be closed")
    func bothSidebarsCanBeClosed() {
        playerService.showQueue = true
        #expect(playerService.showQueue == true)

        playerService.showQueue = false
        #expect(playerService.showQueue == false)
        #expect(playerService.showLyrics == false)
    }

    // MARK: - Clear Queue Tests

    @Test("Clear queue with no current track")
    func clearQueueWithNoCurrentTrack() {
        playerService.clearQueue()

        #expect(playerService.queue.isEmpty)
        #expect(playerService.currentIndex == 0)
    }

    @Test("Clear queue keeps current track")
    func clearQueueKeepsCurrentTrack() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await playerService.playQueue(songs, startingAt: 1)

        playerService.clearQueue()

        #expect(playerService.queue.count == 1)
        #expect(playerService.queue.first?.videoId == "v2")
        #expect(playerService.currentIndex == 0)
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
        await playerService.playFromQueue(at: 2)

        #expect(playerService.currentIndex == 2)
        #expect(playerService.currentTrack?.videoId == "v3")
    }

    @Test("Play from queue invalid index does nothing")
    func playFromQueueInvalidIndexDoesNothing() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
        ]

        await playerService.playQueue(songs, startingAt: 0)
        await playerService.playFromQueue(at: 5)

        #expect(playerService.currentIndex == 0)
    }

    @Test("Play from queue negative index does nothing")
    func playFromQueueNegativeIndexDoesNothing() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
        ]

        await playerService.playQueue(songs, startingAt: 0)
        await playerService.playFromQueue(at: -1)

        #expect(playerService.currentIndex == 0)
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

        #expect(playerService.currentTrack?.videoId == "radio-seed-video")
        #expect(playerService.currentTrack?.title == "Seed Song")
        #expect(playerService.queue.isEmpty == false)
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

        #expect(playerService.queue.count == 1)
        #expect(playerService.queue.first?.videoId == "seed-video")
        #expect(playerService.currentIndex == 0)
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
        playerService.setYTMusicClient(mockClient)

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
        #expect(playerService.queue.count == 4)
        #expect(playerService.queue.first?.videoId == "seed-video", "Seed song should be at front of queue")
        #expect(playerService.currentIndex == 0)
    }

    @Test("Play with radio keeps seed song at front when not in radio")
    func playWithRadioKeepsSeedSongAtFrontWhenNotInRadio() async {
        let mockClient = MockYTMusicClient()
        let radioSongs = [
            Song(id: "radio-1", title: "Radio Song 1", artists: [], videoId: "radio-video-1"),
            Song(id: "radio-2", title: "Radio Song 2", artists: [], videoId: "radio-video-2"),
        ]
        mockClient.radioQueueSongs["seed-video"] = radioSongs
        playerService.setYTMusicClient(mockClient)

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

        #expect(playerService.queue.count == 3)
        #expect(playerService.queue[0].videoId == "seed-video", "Seed song should be first")
        #expect(playerService.queue[1].videoId == "radio-video-1")
        #expect(playerService.queue[2].videoId == "radio-video-2")
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
        playerService.setYTMusicClient(mockClient)

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

        #expect(playerService.queue.count == 3)
        #expect(playerService.queue[0].videoId == "seed-video", "Seed song should be first")
        #expect(playerService.queue[1].videoId == "radio-video-1")
        #expect(playerService.queue[2].videoId == "radio-video-2")
    }

    @Test("Play with radio handles empty radio queue")
    func playWithRadioHandlesEmptyRadioQueue() async {
        let mockClient = MockYTMusicClient()
        playerService.setYTMusicClient(mockClient)

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

        #expect(playerService.queue.count == 1)
        #expect(playerService.queue.first?.videoId == "lonely-video")
    }
}
