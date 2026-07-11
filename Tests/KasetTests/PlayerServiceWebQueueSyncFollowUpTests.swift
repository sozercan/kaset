import Foundation
import Testing
@testable import Kaset

extension PlayerServiceWebQueueSyncTests {
    @Test("Cancelled next discards a delayed radio queue response")
    func cancelledNextDiscardsDelayedRadioQueue() async {
        let mockClient = MockYTMusicClient()
        let radioGate = AsyncGate()
        let seed = TestFixtures.makeSong(id: "radio-seed", title: "Radio Seed")
        mockClient.getRadioQueueGate = radioGate
        mockClient.radioQueueSongs[seed.videoId] = [
            seed,
            TestFixtures.makeSong(id: "stale-radio", title: "Stale Radio"),
        ]
        self.playerService.setYTMusicClient(mockClient)
        self.playerService.currentTrack = seed
        self.playerService.pendingPlayVideoId = seed.videoId
        self.playerService.state = .playing

        let nextTask = Task { @MainActor in
            await self.playerService.next()
        }
        await Self.waitUntilRadioQueueStarts(mockClient: mockClient)
        #expect(mockClient.getRadioQueueCalled)
        nextTask.cancel()
        await radioGate.open()
        await nextTask.value

        #expect(self.playerService.queue.isEmpty)
        #expect(self.playerService.currentTrack?.videoId == seed.videoId)
    }

    @Test("Plain shuffle exposes the next materialized queue entry for native injection")
    func plainShuffleHasDeterministicNextEntry() async {
        await self.playerService.playQueue(TestFixtures.makeSongs(count: 4), startingAt: 0)
        self.playerService.setShuffleMode(.on)

        #expect(self.playerService.expectedQueueIndexAfterCurrentTrack() == 1)
    }

    @Test("Smart shuffle exposes the next materialized queue entry for native injection")
    func smartShuffleHasDeterministicNextEntry() async {
        await self.playerService.playQueue(TestFixtures.makeSongs(count: 4), startingAt: 0)
        self.playerService.setShuffleMode(.smart)

        #expect(self.playerService.expectedQueueIndexAfterCurrentTrack() == 1)
    }

    private static func waitUntilRadioQueueStarts(mockClient: MockYTMusicClient) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while clock.now < deadline {
            if mockClient.getRadioQueueCalled {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Materialized shuffle ends at its last entry when repeat is off")
    func materializedShuffleEndsAtLastEntry() async {
        let songs = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(songs, startingAt: 2)
        self.playerService.shuffleMode = .on
        self.playerService.state = .playing

        await self.playerService.handleTrackEnded(observedVideoId: songs[2].videoId)

        #expect(self.playerService.currentIndex == 2)
        #expect(self.playerService.state == .ended)
        #expect(self.playerService.shouldSuppressAutoplayAfterQueueEnd)
    }

    @Test("Empty mix continuation ends playback at the queue boundary")
    func emptyMixContinuationEndsPlayback() async {
        let mockClient = MockYTMusicClient()
        mockClient.mixQueueContinuationResult = RadioQueueResult(songs: [], continuationToken: nil)
        self.playerService.setYTMusicClient(mockClient)
        let song = TestFixtures.makeSong(id: "last-song")
        await self.playerService.playQueue([song], startingAt: 0)
        self.playerService.mixContinuationToken = "empty-continuation"
        self.playerService.state = .playing

        await self.playerService.handleTrackEnded(observedVideoId: song.videoId)

        #expect(mockClient.getMixQueueContinuationCallCount == 1)
        #expect(self.playerService.mixContinuationToken == nil)
        #expect(self.playerService.state == .ended)
        #expect(self.playerService.shouldSuppressAutoplayAfterQueueEnd)
    }

    @Test("Radio queue replacement preserves the current playback occurrence ID")
    func radioQueueReplacementPreservesCurrentEntryID() async {
        let seed = Song(id: "seed", title: "Seed", artists: [], duration: 180, videoId: "seed-video")
        let suggestion = Song(id: "next", title: "Next", artists: [], duration: 200, videoId: "next-video")
        let mockClient = MockYTMusicClient()
        mockClient.radioQueueSongs[seed.videoId] = [seed, suggestion]
        self.playerService.setYTMusicClient(mockClient)
        await self.playerService.playQueue([seed], startingAt: 0)
        let originalEntryID = self.playerService.currentQueueEntryID

        await self.playerService.fetchAndApplyRadioQueue(for: seed.videoId)

        #expect(self.playerService.currentQueueEntryID == originalEntryID)
        #expect(self.playerService.queue.map(\.videoId) == ["seed-video", "next-video"])
    }

    @Test("Web queue injection waits for full-page navigation to settle")
    func webQueueInjectionWaitsForDocumentNavigation() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        let previousNavigationState = SingletonPlayerWebView.shared.isDocumentNavigationInProgress
        defer { SingletonPlayerWebView.shared.isDocumentNavigationInProgress = previousNavigationState }
        SingletonPlayerWebView.shared.isDocumentNavigationInProgress = true
        let generation = self.playerService.webQueueInjectionGeneration

        self.playerService.syncWebQueue()

        #expect(self.playerService.webQueueInjectionGeneration == generation)
        #expect(self.playerService.pendingWebQueueInjectionVideoId == nil)
    }

    @Test("Consumed injection marker is cleared before a same-video next occurrence")
    func consumedMarkerClearsBeforeSameVideoNextOccurrence() async {
        let songs = [
            Song(id: "a", title: "A", artists: [], duration: 180, videoId: "va"),
            Song(id: "b1", title: "B 1", artists: [], duration: 180, videoId: "vb"),
            Song(id: "b2", title: "B 2", artists: [], duration: 180, videoId: "vb"),
        ]
        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "vb"

        self.playerService.syncWebQueue()

        #expect(self.playerService.injectedWebQueueVideoId == nil)
        #expect(self.playerService.pendingWebQueueInjectionVideoId == nil)
    }

    @Test("Changing the expected next target invalidates stale confirmed and pending injections")
    func changedNextTargetInvalidatesStaleInjectionState() async {
        let songs = [
            Song(id: "a", title: "A", artists: [], duration: 180, videoId: "va"),
            Song(id: "b", title: "B", artists: [], duration: 180, videoId: "vb"),
            Song(id: "c", title: "C", artists: [], duration: 180, videoId: "vc"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "vb"
        self.playerService.pendingWebQueueInjectionVideoId = "vc"
        let generation = self.playerService.webQueueInjectionGeneration

        self.playerService.syncWebQueue()

        #expect(self.playerService.webQueueInjectionGeneration > generation)
        #expect(self.playerService.injectedWebQueueVideoId == nil)
        #expect(self.playerService.pendingWebQueueInjectionVideoId == nil)
    }

    @Test("Native queue injection skips duplicate consecutive video IDs")
    func nativeQueueInjectionSkipsDuplicateVideoIDs() async {
        let duplicate = Song(
            id: "duplicate",
            title: "Duplicate",
            artists: [],
            duration: 180,
            videoId: "same-video"
        )
        await self.playerService.playQueue([duplicate, duplicate], startingAt: 0)
        self.playerService.state = .playing

        self.playerService.syncWebQueue()

        #expect(self.playerService.pendingWebQueueInjectionVideoId == nil)
        #expect(self.playerService.injectedWebQueueVideoId == nil)
    }

    @Test("Metadata-only updates keep a confirmed native queue injection")
    func metadataOnlyUpdateKeepsNativeQueueInjection() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.isKasetInitiatedPlayback = false
        self.playerService.injectedWebQueueVideoId = "v2"

        self.playerService.updateTrackMetadata(
            title: "Updated Song 1",
            artist: "Updated Artist",
            thumbnailUrl: "",
            videoId: "v1"
        )

        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.injectedWebQueueVideoId == "v2")
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
        self.playerService.injectedWebQueueVideoId = "v2"

        await self.playerService.seek(to: 180)

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.pendingPlayVideoId == "v2")
        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
    }

    @Test("Manual seek ends playback when an empty continuation produces no successor")
    func manualSeekWithEmptyContinuationEndsPlayback() async {
        let mockClient = MockYTMusicClient()
        mockClient.mixQueueContinuationResult = RadioQueueResult(songs: [], continuationToken: nil)
        self.playerService.setYTMusicClient(mockClient)
        let song = TestFixtures.makeSong(id: "last-song")
        await self.playerService.playQueue([song], startingAt: 0)
        self.playerService.mixContinuationToken = "empty-continuation"
        self.playerService.state = .playing
        self.playerService.duration = song.duration ?? 180

        await self.playerService.seek(to: self.playerService.duration)

        #expect(mockClient.getMixQueueContinuationCallCount == 1)
        #expect(self.playerService.mixContinuationToken == nil)
        #expect(self.playerService.state == .ended)
        #expect(self.playerService.shouldSuppressAutoplayAfterQueueEnd)
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

    @Test("Deferred restored playback ignores stray playing updates after fallback")
    func deferredRestoredPlaybackIgnoresStrayPlayingUpdatesAfterFallback() {
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
        self.playerService.isAwaitingWebRestoredTrack = false

        self.playerService.updatePlaybackState(isPlaying: true, progress: 61, duration: 0)

        #expect(self.playerService.isPendingRestoredLoadDeferred == true)
        #expect(self.playerService.state == .paused)
        #expect(self.playerService.pendingRestoredSeek == 60)
        #expect(self.playerService.progress == 60)
        #expect(self.playerService.duration == 180)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.hasIssuedAutoplayPauseDuringDeferredRestore == true)
    }

    @Test("Late web metadata after restored fallback does not replace persisted queue")
    func lateWebMetadataAfterRestoredFallbackDoesNotReplaceQueue() {
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
        self.playerService.isAwaitingWebRestoredTrack = false

        self.playerService.updateTrackMetadata(
            title: "Late Web Track",
            artist: "Web Artist",
            thumbnailUrl: "",
            videoId: "web-v1"
        )

        #expect(self.playerService.queue.map(\.videoId) == ["v1", "v2"])
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.pendingPlayVideoId == "v1")
    }

    @Test("Older restored fallback task cannot replace newer restored session")
    func olderRestoredFallbackTaskCannotReplaceNewerRestoredSession() {
        let first = [Song(id: "1", title: "First", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "first")]
        let second = [Song(id: "2", title: "Second", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "second")]

        self.playerService.applyRestoredPlaybackSession(queue: first, currentIndex: 0, progress: 10, duration: 180)
        let firstGeneration = self.playerService.restoredPlaybackSessionGeneration
        self.playerService.applyRestoredPlaybackSession(queue: second, currentIndex: 0, progress: 20, duration: 200)

        #expect(self.playerService.restoredPlaybackSessionGeneration != firstGeneration)
        #expect(self.playerService.currentTrack?.videoId == "second")
        #expect(self.playerService.pendingPlayVideoId == "second")
        #expect(self.playerService.pendingRestoredSeek == 20)
    }

    @Test("Different server-restored track clears persisted seek")
    func differentServerRestoredTrackClearsPersistedSeek() {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
        ]
        self.playerService.applyRestoredPlaybackSession(
            queue: songs,
            currentIndex: 0,
            progress: 60,
            duration: 180
        )

        self.playerService.updateTrackMetadata(
            title: "Server Song",
            artist: "Server Artist",
            thumbnailUrl: "",
            videoId: "server-v2"
        )

        #expect(self.playerService.currentTrack?.videoId == "server-v2")
        #expect(self.playerService.pendingPlayVideoId == "server-v2")
        #expect(self.playerService.pendingRestoredSeek == nil)
        #expect(self.playerService.progress == 0)
        #expect(self.playerService.duration == 0)
        #expect(self.playerService.isPendingRestoredLoadDeferred == true)
    }

    @Test("Same-track restored metadata still refreshes song metadata")
    func sameTrackRestoredMetadataRefreshesSongMetadata() async {
        let mockClient = MockYTMusicClient()
        self.playerService.setYTMusicClient(mockClient)
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

        self.playerService.updateTrackMetadata(
            title: "Song 1",
            artist: "",
            thumbnailUrl: "",
            videoId: "v1"
        )
        try? await Task.sleep(for: .milliseconds(50))

        #expect(mockClient.getSongVideoIds.contains("v1"))
        #expect(self.playerService.queue.map(\.videoId) == ["v1", "v2"])
        #expect(self.playerService.isAwaitingWebRestoredTrack == false)
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
