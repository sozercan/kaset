import Foundation
import Testing
@testable import Kaset

extension PlayerServiceWebQueueSyncTests {
    @Test("Web metadata cannot replace detached playback with a leftover queue")
    func detachedPlaybackIgnoresQueueEnforcement() async {
        let queued = Song(id: "queued", title: "Queued", artists: [], duration: 180, videoId: "queued")
        let detached = Song(
            id: "detached",
            title: "Detached",
            artists: [],
            duration: 180,
            videoId: "detached",
            feedbackTokens: .init(add: nil, remove: nil)
        )
        await self.playerService.playQueue([queued], startingAt: 0)
        await self.playerService.play(song: detached)

        self.playerService.updateTrackMetadata(
            title: "Observed Detached",
            artist: "",
            thumbnailUrl: "",
            videoId: detached.videoId
        )
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(self.playerService.queue == [queued])
        #expect(self.playerService.currentTrack?.videoId == detached.videoId)
        #expect(self.playerService.activePlaybackQueueEntryID == nil)
    }

    @Test("Detached manual transport does not adopt the leftover queue")
    func detachedManualTransportIgnoresLeftoverQueue() async {
        let queue = [
            Song(id: "manual-queued-1", title: "Queued 1", artists: [], duration: 180, videoId: "manual-queued-1"),
            Song(id: "manual-queued-2", title: "Queued 2", artists: [], duration: 180, videoId: "manual-queued-2"),
        ]
        let detached = Song(
            id: "manual-detached",
            title: "Detached",
            artists: [],
            duration: 180,
            videoId: "manual-detached",
            feedbackTokens: FeedbackTokens(add: nil, remove: nil)
        )
        await self.playerService.playQueue(queue, startingAt: 0)
        await self.playerService.play(song: detached)

        await self.playerService.next()

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == detached.videoId)
        #expect(self.playerService.activePlaybackQueueEntryID == nil)

        self.playerService.currentIndex = 1
        self.playerService.progress = 0
        await self.playerService.previous()

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == detached.videoId)
        #expect(self.playerService.activePlaybackQueueEntryID == nil)
    }

    @Test("Stopped queue transport can still navigate the native queue")
    func stoppedQueueTransportStillNavigatesNativeQueue() async {
        let queue = [
            Song(id: "stopped-nav-1", title: "Queued 1", artists: [], duration: 180, videoId: "stopped-nav-1"),
            Song(id: "stopped-nav-2", title: "Queued 2", artists: [], duration: 180, videoId: "stopped-nav-2"),
        ]
        await self.playerService.playQueue(queue, startingAt: 0)
        await self.playerService.stop()

        await self.playerService.next()

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == queue[1].videoId)
        #expect(self.playerService.activePlaybackQueueEntryID == self.playerService.queueEntryIDs[1])
    }

    @Test("Detached playback ending does not advance the leftover queue")
    func detachedTrackEndIgnoresLeftoverQueue() async {
        let queue = [
            Song(id: "queued-1", title: "Queued 1", artists: [], duration: 180, videoId: "queued-1"),
            Song(id: "queued-2", title: "Queued 2", artists: [], duration: 180, videoId: "queued-2"),
        ]
        let detached = Song(
            id: "detached-end",
            title: "Detached",
            artists: [],
            duration: 180,
            videoId: "detached-end",
            feedbackTokens: .init(add: nil, remove: nil)
        )
        await self.playerService.playQueue(queue, startingAt: 0)
        await self.playerService.play(song: detached)
        let occurrence = self.playerService.currentMusicPlaybackOccurrence

        await self.playerService.handleTrackEnded(
            observedVideoId: detached.videoId,
            playbackOccurrence: occurrence
        )

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.queue == queue)
        #expect(self.playerService.currentTrack?.videoId == detached.videoId)
        #expect(self.playerService.state == .ended)
    }

    @Test("Observed queue drift persists only after playback ownership realigns")
    func observedQueueDriftPersistsRealignedOwnership() async {
        self.playerService.clearSavedQueue()
        defer { self.playerService.clearSavedQueue() }
        let songs = [
            Song(id: "persist-v1", title: "Persist 1", artists: [], duration: 180, videoId: "persist-v1"),
            Song(id: "persist-v2", title: "Persist 2", artists: [], duration: 180, videoId: "persist-v2"),
            Song(id: "persist-v3", title: "Persist 3", artists: [], duration: 180, videoId: "persist-v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        let matchedEntryID = self.playerService.queueEntryIDs[1]
        self.playerService.updateTrackMetadata(
            title: songs[0].title,
            artist: "",
            thumbnailUrl: "",
            videoId: songs[0].videoId
        )

        self.playerService.updateTrackMetadata(
            title: songs[1].title,
            artist: "",
            thumbnailUrl: "",
            videoId: songs[1].videoId
        )

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentQueueEntryID == matchedEntryID)
        #expect(self.playerService.activePlaybackQueueEntryID == matchedEntryID)
        #expect(self.playerService.currentTrack?.videoId == songs[1].videoId)

        let restored = PlayerService()
        #expect(restored.restoreQueueFromPersistence())
        #expect(restored.queue.map(\.videoId) == songs.map(\.videoId))
        #expect(restored.currentIndex == 1)
        #expect(restored.currentTrack?.videoId == songs[1].videoId)

        await self.playerService.handleTrackEnded(observedVideoId: songs[1].videoId)
        #expect(self.playerService.currentIndex == 2)
        #expect(self.playerService.currentTrack?.videoId == songs[2].videoId)
    }

    @Test("Ambiguous duplicate video IDs do not select the first queue entry")
    func ambiguousObservedVideoIDDoesNotSelectFirstDuplicate() async {
        let current = Song(
            id: "current",
            title: "Current",
            artists: [],
            duration: 180,
            videoId: "v1",
            feedbackTokens: .init(add: nil, remove: nil)
        )
        let duplicate = Song(
            id: "duplicate",
            title: "Duplicate",
            artists: [],
            duration: 180,
            videoId: "v2",
            feedbackTokens: .init(add: nil, remove: nil)
        )
        let currentEntryID = UUID()
        self.playerService.setQueue(entries: [
            QueueEntry(id: currentEntryID, song: current),
            QueueEntry(id: UUID(), song: duplicate),
            QueueEntry(id: UUID(), song: duplicate),
        ])
        await self.playerService.playFromQueue(at: 0)
        self.playerService.isKasetInitiatedPlayback = false

        self.playerService.updateTrackMetadata(
            title: duplicate.title,
            artist: "",
            thumbnailUrl: "",
            videoId: duplicate.videoId
        )
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentQueueEntryID == currentEntryID)
        #expect(self.playerService.activePlaybackQueueEntryID == currentEntryID)
        #expect(self.playerService.currentTrack?.videoId == current.videoId)
    }

    @Test("A scheduled drift replay cannot replace a newer queue")
    func scheduledDriftReplayCannotReplaceNewerQueue() async {
        let oldSong = Song(
            id: "old",
            title: "Old",
            artists: [],
            duration: 180,
            videoId: "old",
            feedbackTokens: .init(add: nil, remove: nil)
        )
        let newSong = Song(
            id: "new",
            title: "New",
            artists: [],
            duration: 180,
            videoId: "new",
            feedbackTokens: .init(add: nil, remove: nil)
        )
        await self.playerService.playQueue([oldSong], startingAt: 0)
        self.playerService.isKasetInitiatedPlayback = false

        self.playerService.updateTrackMetadata(
            title: "Unexpected",
            artist: "",
            thumbnailUrl: "",
            videoId: "unexpected"
        )
        await self.playerService.playQueue([newSong], startingAt: 0)
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(self.playerService.queue == [newSong])
        #expect(self.playerService.currentTrack?.videoId == newSong.videoId)
        #expect(self.playerService.activePlaybackQueueEntryID == self.playerService.currentQueueEntryID)
    }

    @Test("An admitted end cannot advance after a newer pause intent")
    func staleIntentTrackEndCannotAdvanceQueue() async {
        let songs = [
            Song(id: "1", title: "One", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Two", artists: [], duration: 180, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        let endedOccurrence = self.playerService.currentMusicPlaybackOccurrence
        let admittedIntent = self.playerService.currentMusicPlaybackIntent

        await self.playerService.pause()
        await self.playerService.handleTrackEnded(
            observedVideoId: "v1",
            playbackOccurrence: endedOccurrence,
            intent: admittedIntent
        )

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.state == .paused)
    }

    @Test("An end emitted after pause is consumed without advancing the queue")
    func currentPauseIntentTrackEndCannotAdvanceQueue() async {
        let songs = [
            Song(id: "pause-end-1", title: "One", artists: [], duration: 180, videoId: "pause-end-v1"),
            Song(id: "pause-end-2", title: "Two", artists: [], duration: 180, videoId: "pause-end-v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        let endedOccurrence = self.playerService.currentMusicPlaybackOccurrence
        let pauseIntent = self.playerService.beginMusicPlaybackIntent()
        await self.playerService.pause(intent: pauseIntent)

        await self.playerService.handleTrackEnded(
            observedVideoId: songs[0].videoId,
            playbackOccurrence: endedOccurrence,
            intent: pauseIntent
        )

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == songs[0].videoId)
        #expect(self.playerService.state == .paused)
        #expect(!self.playerService.shouldResumeAfterInterruption)
    }

    @Test("Shuffle admits an already-emitted end for the active occurrence")
    func shuffleDoesNotDiscardPendingTrackEnd() async {
        let songs = [
            Song(id: "shuffle-end-a", title: "A", artists: [], duration: 180, videoId: "shuffle-end-a"),
            Song(id: "shuffle-end-b", title: "B", artists: [], duration: 180, videoId: "shuffle-end-b"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        let occurrence = self.playerService.currentMusicPlaybackOccurrence
        let emittedAt = Date().timeIntervalSince1970 * 1000

        self.playerService.shuffleQueue()
        let shuffleIntent = self.playerService.currentMusicPlaybackIntent
        #expect(self.playerService.acceptsMusicTerminalBridgeEvent(
            intent: shuffleIntent,
            eventIssuedAtMilliseconds: emittedAt
        ))
        await self.playerService.handleTrackEnded(
            observedVideoId: songs[0].videoId,
            playbackOccurrence: occurrence,
            intent: shuffleIntent
        )

        #expect(self.playerService.currentTrack?.videoId == songs[1].videoId)
    }

    @Test("Clear queue admits an already-emitted end for the retained occurrence")
    func clearQueueDoesNotDiscardPendingTrackEnd() async throws {
        self.playerService.shuffleMode = .off
        while self.playerService.repeatMode != .off {
            self.playerService.advanceRepeatMode()
        }
        let songs = [
            Song(id: "clear-end-a", title: "A", artists: [], duration: 180, videoId: "clear-end-a"),
            Song(id: "clear-end-b", title: "B", artists: [], duration: 180, videoId: "clear-end-b"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        let occurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)
        let retainedEntryID = try #require(self.playerService.activePlaybackQueueEntryID)

        self.playerService.clearQueue()
        let clearIntent = self.playerService.currentMusicPlaybackIntent
        self.playerService.musicPlaybackIntentIssuedAtMilliseconds = 1000

        #expect(self.playerService.currentMusicPlaybackOccurrence == occurrence)
        #expect(self.playerService.activePlaybackQueueEntryID == retainedEntryID)
        #expect(!self.playerService.acceptsMusicBridgeEvent(
            intent: clearIntent,
            eventIssuedAtMilliseconds: 999
        ))
        try #require(self.playerService.acceptsMusicTerminalBridgeEvent(
            intent: clearIntent,
            eventIssuedAtMilliseconds: 999
        ))

        await self.playerService.handleTrackEnded(
            observedVideoId: songs[0].videoId,
            playbackOccurrence: occurrence,
            intent: clearIntent
        )

        #expect(self.playerService.queueEntryIDs == [retainedEntryID])
        #expect(self.playerService.state == .ended)
        #expect(self.playerService.shouldSuppressAutoplayAfterQueueEnd)
    }

    @Test("Near-end metadata cannot rekey consecutive duplicate video entries")
    func nearEndDuplicateVideoDefersUntilEnded() async throws {
        let first = Song(id: "first", title: "First", artists: [], duration: 180, videoId: "shared")
        let second = Song(id: "second", title: "Second", artists: [], duration: 180, videoId: "shared")
        let third = Song(id: "third", title: "Third", artists: [], duration: 180, videoId: "third")
        let firstID = UUID()
        let secondID = UUID()
        self.playerService.setQueue(entries: [
            QueueEntry(id: firstID, song: first),
            QueueEntry(id: secondID, song: second),
            QueueEntry(id: UUID(), song: third),
        ])
        await self.playerService.playFromQueue(at: 0)
        self.playerService.isKasetInitiatedPlayback = false
        self.playerService.songNearingEnd = true
        let outgoingOccurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)

        self.playerService.updateTrackMetadata(
            title: second.title,
            artist: "",
            thumbnailUrl: "",
            videoId: second.videoId,
            playbackOccurrence: outgoingOccurrence
        )

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentQueueEntryID == firstID)
        #expect(self.playerService.activePlaybackQueueEntryID == firstID)

        await self.playerService.handleTrackEnded(
            observedVideoId: first.videoId,
            playbackOccurrence: outgoingOccurrence
        )

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentQueueEntryID == secondID)
        #expect(self.playerService.activePlaybackQueueEntryID == secondID)
    }

    @Test("Near-end queue correction owns a late ended callback")
    func nearEndQueueCorrectionThenLateEndedDoesNotDoubleAdvance() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.isKasetInitiatedPlayback = false
        self.playerService.songNearingEnd = true
        let outgoingOccurrence = self.playerService.currentMusicPlaybackOccurrence

        self.playerService.updateTrackMetadata(
            title: "Unexpected autoplay",
            artist: "Someone else",
            thumbnailUrl: "",
            videoId: "unexpected",
            playbackOccurrence: outgoingOccurrence
        )
        try? await Task.sleep(for: .milliseconds(100))
        #expect(self.playerService.currentIndex == 1)

        await self.playerService.handleTrackEnded(
            observedVideoId: "v1",
            playbackOccurrence: outgoingOccurrence
        )

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
    }

    @Test("In-place repeat-one replay clears the terminal pause fence")
    func repeatOneReplayClearsPauseFence() async {
        let song = Song(
            id: "1",
            title: "Song 1",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "v1"
        )
        await self.playerService.playQueue([song], startingAt: 0)
        self.playerService.markUserInteractedThisSession()
        self.playerService.currentWebPlaybackVideoId = { "v1" }
        self.playerService.cycleRepeatMode()
        self.playerService.cycleRepeatMode()

        await self.playerService.handleTrackEnded(
            observedVideoId: "v1",
            playbackOccurrence: self.playerService.currentMusicPlaybackOccurrence
        )

        #expect(!self.playerService.isExplicitPauseIntentActive)
        #expect(self.playerService.isAwaitingPlaybackConfirmation)
        #expect(self.playerService.shouldResumeAfterInterruption)
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
        let intent = self.playerService.currentMusicPlaybackIntent
        await self.playerService.playFromQueue(at: 5)

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentMusicPlaybackIntent == intent)
    }

    @Test("Play from queue negative index does nothing")
    func playFromQueueNegativeIndexDoesNothing() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
        ]

        await playerService.playQueue(songs, startingAt: 0)
        let intent = self.playerService.currentMusicPlaybackIntent
        await self.playerService.playFromQueue(at: -1)

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentMusicPlaybackIntent == intent)
    }

    @Test("Play from queue missing entry ID does nothing")
    func playFromQueueMissingEntryIDDoesNothing() async {
        let song = Song(id: "missing-entry", title: "Song", artists: [], duration: 180, videoId: "missing-entry")
        await self.playerService.playQueue([song], startingAt: 0)
        let intent = self.playerService.currentMusicPlaybackIntent

        await self.playerService.playFromQueue(entryID: UUID())

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == song.videoId)
        #expect(self.playerService.currentMusicPlaybackIntent == intent)
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

    @Test("Resuming a pre-bind terminal occurrence starts a fresh native occurrence")
    func resumeAfterPreBindTerminalStartsFreshOccurrence() async throws {
        let song = Song(
            id: "1",
            title: "Song 1",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "v1"
        )
        await self.playerService.play(song: song)
        let endedOccurrence = self.playerService.beginNativeMusicPlaybackOccurrence(videoId: "v1")

        await self.playerService.seek(to: 180)
        #expect(self.playerService.state == .ended)
        #expect(self.playerService.currentMusicPlaybackOccurrence == endedOccurrence)

        await self.playerService.resume()
        let replayOccurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)
        #expect(replayOccurrence.nativeGeneration > endedOccurrence.nativeGeneration)

        let firstWebOccurrence = try #require(self.playerService.bindWebMusicPlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1,
            nativeGeneration: replayOccurrence.nativeGeneration,
            videoId: "v1"
        ))
        #expect(self.playerService.acceptsWebMusicPlaybackOccurrence(firstWebOccurrence))
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
