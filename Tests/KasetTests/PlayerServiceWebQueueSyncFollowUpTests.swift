import Foundation
import Testing
@testable import Kaset

extension PlayerServiceWebQueueSyncTests {
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

    @Test("Play with radio materializes queue when shuffle is enabled")
    func playWithRadioMaterializesQueueWhenShuffleEnabled() async {
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
        let expectedOriginalOrder = ["seed-video", "radio-video-1", "radio-video-2", "radio-video-3"]

        self.playerService.toggleShuffle()
        await self.playerService.playWithRadio(song: song)

        #expect(self.playerService.shuffleEnabled == true)
        #expect(self.playerService.queue.count == expectedOriginalOrder.count)
        #expect(self.playerService.queue.first?.videoId == "seed-video")
        #expect(Set(self.playerService.queue.map(\.videoId)) == Set(expectedOriginalOrder))
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.queueOrderBeforeShuffle?.map(\.song.videoId) == expectedOriginalOrder)
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

    // MARK: - Manual Seek to End Tests

    @Test("Manual seek to end of track advances to next queue song")
    func manualSeekToEndAdvancesQueue() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.duration = 180

        await self.playerService.seek(to: 180)

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.pendingPlayVideoId == "v2")
    }

    @Test("Manual seek within end-threshold still advances queue")
    func manualSeekWithinEndThresholdAdvancesQueue() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.duration = 180

        await self.playerService.seek(to: 180 - PlayerService.seekToEndThreshold + 0.01)

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.pendingPlayVideoId == "v2")
    }

    @Test("Manual seek to mid-track does not advance queue")
    func manualSeekToMidTrackDoesNotAdvanceQueue() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.duration = 180

        await self.playerService.seek(to: 90)

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.pendingPlayVideoId == "v1")
        #expect(self.playerService.progress == 90)
    }

    @Test("Manual seek to end with repeat one replays the same song")
    func manualSeekToEndWithRepeatOneReplaysSameSong() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.cycleRepeatMode()
        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .one)
        self.playerService.duration = 180

        await self.playerService.seek(to: 180)

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.pendingPlayVideoId == "v1")
    }

    @Test("Manual seek to end of last queue song with repeat off pauses at end")
    func manualSeekToEndOfLastQueueSongPausesPlayback() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.duration = 200

        await self.playerService.seek(to: 200)

        #expect(self.playerService.state == .ended)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.shouldSuppressAutoplayAfterQueueEnd == true)
    }

    @Test("Manual seek to end with repeat all wraps from last song to first")
    func manualSeekToEndWithRepeatAllWrapsToFirst() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .all)
        self.playerService.duration = 200

        await self.playerService.seek(to: 200)

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.pendingPlayVideoId == "v1")
    }

    @Test("Restored seek before load is not treated as seek-to-end")
    func manualSeekToEndDuringRestorationIsDeferred() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        self.playerService.applyRestoredPlaybackSession(
            queue: songs,
            currentIndex: 0,
            progress: 60,
            duration: 180
        )

        #expect(self.playerService.isPendingRestoredLoadDeferred == true)

        await self.playerService.seek(to: 180)

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.pendingPlayVideoId == "v1")
        #expect(self.playerService.pendingRestoredSeek == 180)
    }

    @Test("Identity-switch reload is skipped while a restored session is deferred")
    func identitySwitchReloadSkippedWhenDeferred() {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
        ]
        self.playerService.applyRestoredPlaybackSession(
            queue: songs,
            currentIndex: 0,
            progress: 60,
            duration: 180
        )
        #expect(self.playerService.isPendingRestoredLoadDeferred == true)

        // A verified-identity signal must NOT force-load a deferred restored
        // session (which would clear the explicit-resume gate and load the
        // playback page + stats before the user resumes).
        self.playerService.reloadCurrentTrackForIdentitySwitch()

        #expect(self.playerService.isPendingRestoredLoadDeferred == true)
        #expect(self.playerService.state == .paused)
    }
}
