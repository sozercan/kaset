import Foundation
import Testing
@testable import Kaset

@MainActor
private extension PlayerService {
    var expectedQueueIndexForTesting: Int? {
        guard !self.queue.isEmpty else { return nil }
        if self.repeatMode == .one {
            return self.currentIndex
        }
        guard !self.shuffleEnabled else { return nil }
        if self.currentIndex < self.queue.count - 1 {
            return self.currentIndex + 1
        }
        if self.repeatMode == .all {
            return 0
        }
        return nil
    }
}

// MARK: - PlayerServiceWebQueueSyncTests

/// Web queue sync, next/previous stack, repeat-one, metadata drift, and radio-related PlayerService tests.
@Suite(.serialized, .tags(.service))
@MainActor
struct PlayerServiceWebQueueSyncTests {
    var playerService: PlayerService

    init() {
        UserDefaults.standard.removeObject(forKey: "playerVolume")
        UserDefaults.standard.removeObject(forKey: "playerVolumeBeforeMute")
        self.playerService = PlayerService()
    }

    // MARK: - Forward skip / Previous stack

    @Test("Previous seeks to start first when progress > 3; second Previous undoes next skip")
    func previousSeeksToStartBeforeUndoingForwardSkip() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.progress = 100
        await self.playerService.next()
        #expect(self.playerService.currentIndex == 1)
        self.playerService.progress = 100
        await self.playerService.previous()
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.progress <= 3)
        await self.playerService.previous()
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.pendingPlayVideoId == "v1")
    }

    @Test("Two next presses then two previous presses restore original index")
    func chainedNextPreviousWalksBackThroughStack() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        await self.playerService.next()
        await self.playerService.next()
        #expect(self.playerService.currentIndex == 2)
        await self.playerService.previous()
        #expect(self.playerService.currentIndex == 1)
        await self.playerService.previous()
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.pendingPlayVideoId == "v1")
    }

    @Test("Manual next without queue materializes radio queue through API")
    func manualNextWithoutQueueMaterializesRadioQueueThroughAPI() async {
        let mockClient = MockYTMusicClient()
        let seed = Song(id: "seed", title: "Seed", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "seed-video")
        let radioSongs = [
            Song(id: "radio-1", title: "Radio 1", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "radio-video-1"),
            Song(id: "radio-2", title: "Radio 2", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "radio-video-2"),
        ]
        mockClient.radioQueueSongs[seed.videoId] = radioSongs
        self.playerService.setYTMusicClient(mockClient)
        self.playerService.currentTrack = seed
        self.playerService.pendingPlayVideoId = seed.videoId
        self.playerService.state = .playing

        await self.playerService.next()

        #expect(mockClient.getRadioQueueCalled == true)
        #expect(mockClient.getRadioQueueVideoIds == [seed.videoId])
        #expect(self.playerService.queue.map(\.videoId) == ["seed-video", "radio-video-1", "radio-video-2"])
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "radio-video-1")
        #expect(self.playerService.progress == 0)
    }

    @Test("Stale metadata after manual next cannot realign backward before intended confirmation")
    func staleMetadataAfterManualNextCannotRealignBackwardBeforeIntendedConfirmation() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing

        await self.playerService.next()
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")

        // YouTube can emit stale metadata for the previous video while Kaset's
        // manual navigation load is still in flight. Multiple stale frames must
        // not be allowed to realign the native queue back to the old song.
        self.playerService.updateTrackMetadata(
            title: "Song 1",
            artist: "",
            thumbnailUrl: "",
            videoId: "v1"
        )
        self.playerService.updateTrackMetadata(
            title: "Song 1",
            artist: "",
            thumbnailUrl: "",
            videoId: "v1"
        )

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.pendingPlayVideoId == "v2")
    }

    @Test("Stale metadata after manual next confirmation cannot realign backward")
    func staleMetadataAfterManualNextConfirmationCannotRealignBackward() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing

        await self.playerService.next()
        #expect(self.playerService.currentIndex == 1)

        self.playerService.updateTrackMetadata(
            title: "Song 2",
            artist: "",
            thumbnailUrl: "",
            videoId: "v2"
        )

        // Stale old-song metadata can still arrive after the intended video was
        // briefly confirmed. It must not be treated as a legitimate native
        // in-queue move back to the previous item.
        self.playerService.updateTrackMetadata(
            title: "Song 1",
            artist: "",
            thumbnailUrl: "",
            videoId: "v1"
        )

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.pendingPlayVideoId == "v2")
    }

    @Test("Expired unconfirmed manual next protection allows later in-queue movement")
    func expiredUnconfirmedManualNextProtectionAllowsLaterInQueueMovement() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing

        await self.playerService.next()
        #expect(self.playerService.currentIndex == 1)
        self.playerService.protectedQueueNavigationStartedAt = ContinuousClock.now - .seconds(25)

        self.playerService.updateTrackMetadata(
            title: "Song 3",
            artist: "",
            thumbnailUrl: "",
            videoId: "v3"
        )

        #expect(self.playerService.currentIndex == 2)
        #expect(self.playerService.currentTrack?.videoId == "v3")
    }

    @Test("Manual next ignores native injection marker and loads target deterministically")
    func manualNextIgnoresNativeInjectionMarkerAndLoadsTargetDeterministically() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"

        await self.playerService.next()

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.pendingPlayVideoId == "v2")
        #expect(self.playerService.injectedWebQueueVideoId == nil)
        #expect(self.playerService.pendingWebQueueInjectionVideoId == nil)
    }

    @Test("Manual next resets progress before persisting target queue song")
    func manualNextResetsProgressBeforePersistingTargetQueueSong() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.progress = 179
        self.playerService.duration = 180
        self.playerService.injectedWebQueueVideoId = "v2"

        await self.playerService.next()

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.progress == 0)
        #expect(self.playerService.duration == 200)
    }

    @Test("Manual next clears consumed injection marker for duplicate video IDs")
    func manualNextClearsConsumedInjectionMarkerForDuplicateVideoIDs() async {
        let duplicate = Song(id: "dup", title: "Duplicate", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v2")
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            duplicate,
            duplicate,
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"

        await self.playerService.next()

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.injectedWebQueueVideoId == nil)
        #expect(self.playerService.expectedQueueIndexForTesting == 2)
    }

    @Test("Saving an empty queue clears web queue injection state")
    func savingEmptyQueueClearsWebQueueInjectionState() {
        self.playerService.injectedWebQueueVideoId = "stale"
        self.playerService.pendingWebQueueInjectionVideoId = "stale"

        self.playerService.saveQueueForPersistence()

        #expect(self.playerService.injectedWebQueueVideoId == nil)
        #expect(self.playerService.pendingWebQueueInjectionVideoId == nil)
    }

    @Test("Removing injected next song clears web queue injection state")
    func removingInjectedNextSongClearsWebQueueInjectionState() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"

        self.playerService.removeFromQueue(videoIds: ["v2"])

        #expect(self.playerService.queue.map(\.videoId) == ["v1"])
        #expect(self.playerService.injectedWebQueueVideoId == nil)
        #expect(self.playerService.pendingWebQueueInjectionVideoId == nil)
    }

    @Test("Web queue injection result is trusted only after successful current next confirmation")
    func webQueueInjectionResultRequiresSuccessfulExpectedNextConfirmation() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)

        self.playerService.webQueueInjectionGeneration = 1
        self.playerService.pendingWebQueueInjectionVideoId = "v3"
        self.playerService.handleWebQueueInjectionResult(
            videoId: "v3",
            attemptGeneration: 1,
            success: true,
            reason: nil
        )
        #expect(self.playerService.injectedWebQueueVideoId == nil)
        #expect(self.playerService.pendingWebQueueInjectionVideoId == nil)

        self.playerService.pendingWebQueueInjectionVideoId = "v2"
        self.playerService.handleWebQueueInjectionResult(
            videoId: "v2",
            attemptGeneration: 2,
            success: false,
            reason: "timeout"
        )
        #expect(self.playerService.injectedWebQueueVideoId == nil)
        #expect(self.playerService.pendingWebQueueInjectionVideoId == nil)

        self.playerService.handleWebQueueInjectionResult(
            videoId: "v2",
            attemptGeneration: 2,
            success: true,
            reason: "stale"
        )
        #expect(self.playerService.injectedWebQueueVideoId == nil)

        self.playerService.pendingWebQueueInjectionVideoId = "v2"
        self.playerService.handleWebQueueInjectionResult(
            videoId: "v2",
            attemptGeneration: 3,
            success: true,
            reason: "queue-readback-confirmed"
        )
        #expect(self.playerService.injectedWebQueueVideoId == "v2")
        #expect(self.playerService.pendingWebQueueInjectionVideoId == nil)
    }

    // MARK: - Next with Shuffle Tests

    @Test("Next with repeat one advances to the following queue song")
    func nextWithRepeatOneAdvancesToFollowingQueueSong() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.cycleRepeatMode()
        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .one)

        #expect(self.playerService.currentIndex == 1)

        await self.playerService.next()

        #expect(self.playerService.currentIndex == 2)
        #expect(self.playerService.pendingPlayVideoId == songs[2].videoId)
        #expect(self.playerService.currentTrack?.videoId == songs[2].videoId)
    }

    @Test("Next with shuffle and repeat one follows materialized queue")
    func nextWithShuffleAndRepeatOneFollowsQueue() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.toggleShuffle()
        #expect(self.playerService.shuffleEnabled == true)
        let queuedVideoIds = self.playerService.queue.map(\.videoId)
        #expect(queuedVideoIds.first == "v2")

        self.playerService.cycleRepeatMode()
        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .one)

        await self.playerService.next()

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == queuedVideoIds[1])
    }

    @Test("Near-end autoplay while repeat one does not advance queue index")
    func nearEndAutoplayWithRepeatOneDoesNotAdvanceQueue() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.cycleRepeatMode()
        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .one)
        self.playerService.isKasetInitiatedPlayback = false
        self.playerService.songNearingEnd = true

        self.playerService.updateTrackMetadata(
            title: "Autoplay Suggestion",
            artist: "Someone Else",
            thumbnailUrl: "",
            videoId: "v3"
        )

        try? await Task.sleep(for: .milliseconds(200))

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.pendingPlayVideoId == "v2")
    }

    @Test("Repeat one does not realign queue when YouTube loads another in-queue video")
    func repeatOneDoesNotRealignQueueWhenYouTubeLoadsAnotherInQueueVideo() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.cycleRepeatMode()
        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .one)
        self.playerService.isKasetInitiatedPlayback = false

        self.playerService.updateTrackMetadata(
            title: "Song 3",
            artist: "Artist",
            thumbnailUrl: "",
            videoId: "v3"
        )

        try? await Task.sleep(for: .milliseconds(150))

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.pendingPlayVideoId == "v2")
    }

    @Test("Track ended with repeat one advances via same song reload")
    func trackEndedRepeatOneReloadsSameSong() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.cycleRepeatMode()
        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .one)

        await self.playerService.handleTrackEnded(observedVideoId: "v1")

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.pendingPlayVideoId == "v1")
    }

    @Test("Repeat one recovers when title drifts before videoId is sent")
    func repeatOneRecoversWhenTitleDriftsBeforeVideoId() async {
        let songs = [
            Song(
                id: "1",
                title: "Song 1",
                artists: [Artist(id: "a1", name: "Artist 1")],
                album: nil,
                duration: 180,
                thumbnailURL: nil,
                videoId: "v1"
            ),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.cycleRepeatMode()
        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .one)
        self.playerService.isKasetInitiatedPlayback = false

        self.playerService.updateTrackMetadata(
            title: "Autoplay Suggestion",
            artist: "Someone Else",
            thumbnailUrl: "",
            videoId: nil
        )

        try? await Task.sleep(for: .milliseconds(150))

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.pendingPlayVideoId == "v1")
    }

    @Test("Track ended with repeat one still runs when WebView reports autoplay video id")
    func trackEndedRepeatOneRunsWhenObservedIdIsAutoplayNotQueueTrack() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.cycleRepeatMode()
        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .one)

        await self.playerService.handleTrackEnded(observedVideoId: "youtubeAutoplayOther")

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.pendingPlayVideoId == "v1")
    }

    @Test("Track ended with repeat one replays even without an active queue")
    func trackEndedRepeatOneReplaysWithoutQueue() async {
        let song = Song(
            id: "solo-1",
            title: "Solo Song",
            artists: [Artist(id: "solo-artist", name: "Solo Artist")],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "solo-video"
        )

        await self.playerService.play(song: song)
        #expect(self.playerService.queue.isEmpty)

        self.playerService.cycleRepeatMode()
        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .one)

        await self.playerService.handleTrackEnded(observedVideoId: "solo-video")

        #expect(self.playerService.pendingPlayVideoId == "solo-video")
        #expect(self.playerService.state != .ended)
    }

    @Test("Next with shuffle follows visible queue order")
    func nextWithShuffleFollowsVisibleQueueOrder() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
            Song(id: "4", title: "Song 4", artists: [], album: nil, duration: 240, thumbnailURL: nil, videoId: "v4"),
            Song(id: "5", title: "Song 5", artists: [], album: nil, duration: 260, thumbnailURL: nil, videoId: "v5"),
        ]

        await playerService.playQueue(songs, startingAt: 0)
        self.playerService.toggleShuffle()
        #expect(self.playerService.shuffleEnabled == true)
        let queuedVideoIds = self.playerService.queue.map(\.videoId)

        for expectedIndex in 1 ..< queuedVideoIds.count {
            await self.playerService.next()
            #expect(self.playerService.currentIndex == expectedIndex)
            #expect(self.playerService.currentTrack?.videoId == queuedVideoIds[expectedIndex])
        }
    }

    @Test("UpdateTrackMetadata corrects YouTube autoplay with Kaset-initiated playback")
    func updateTrackMetadataCorrectsYouTubeAutoplay() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await playerService.playQueue(songs, startingAt: 0)
        self.playerService.toggleShuffle()

        // Simulate calling next which sets isKasetInitiatedPlayback
        await self.playerService.next()

        // Get the song that Kaset intended to play
        let intendedSong = self.playerService.queue[self.playerService.currentIndex]

        // Simulate YouTube loading a DIFFERENT track (not from our queue)
        // This should trigger a re-play of the intended track
        self.playerService.updateTrackMetadata(
            title: "YouTube Autoplay Song",
            artist: "Random Artist",
            thumbnailUrl: "",
            videoId: "youtube-autoplay"
        )

        // Give async correction task time to run
        try? await Task.sleep(for: .milliseconds(100))

        #expect(self.playerService.currentTrack?.videoId == intendedSong.videoId)
        #expect(self.playerService.currentTrack?.title == intendedSong.title)
    }

    @Test("UpdateTrackMetadata keeps queue song when Web metadata is stale")
    func updateTrackMetadataKeepsQueueSongWhenMetadataIsStale() async {
        let songs = [
            Song(
                id: "v1",
                title: "You Make My Dreams (Come True)",
                artists: [Artist(id: "artist-1", name: "Daryl Hall & John Oates")],
                album: nil,
                duration: 180,
                thumbnailURL: nil,
                videoId: "v1"
            ),
            Song(id: "v2", title: "Come Together", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)

        self.playerService.updateTrackMetadata(
            title: "Private Eyes",
            artist: "Daryl Hall & John Oates",
            thumbnailUrl: "",
            videoId: "v1"
        )

        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.currentTrack?.title == "You Make My Dreams (Come True)")
        #expect(self.playerService.isKasetInitiatedPlayback == false)
    }

    @Test("Near-end videoId-only transition keeps expected queue song visible")
    func nearEndVideoIdOnlyTransitionKeepsExpectedQueueSongVisible() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [Artist(id: "artist-1", name: "Artist 1")], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [Artist(id: "artist-2", name: "Artist 2")], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [Artist(id: "artist-3", name: "Artist 3")], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.isKasetInitiatedPlayback = false
        self.playerService.updatePlaybackState(isPlaying: true, progress: 179, duration: 180)

        self.playerService.updateTrackMetadata(
            title: "",
            artist: "",
            thumbnailUrl: "",
            videoId: "v2"
        )

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.currentTrack?.title == "Song 2")
        #expect(self.playerService.currentTrack?.artistsDisplay == "Artist 2")
    }

    @Test("Unexpected autoplay at end of queue is stopped")
    func unexpectedAutoplayAtEndOfQueueIsStopped() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.isKasetInitiatedPlayback = false
        self.playerService.updatePlaybackState(isPlaying: true, progress: 199, duration: 200)

        self.playerService.updateTrackMetadata(
            title: "Unexpected Song",
            artist: "Random Artist",
            thumbnailUrl: "",
            videoId: "unexpected"
        )

        #expect(self.playerService.state == .ended)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
    }

    @Test("Autoplay after native queue end is suppressed")
    func autoplayAfterQueueEndIsSuppressed() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.isKasetInitiatedPlayback = false

        await self.playerService.handleTrackEnded(observedVideoId: "v2")
        self.playerService.updatePlaybackState(isPlaying: true, progress: 0, duration: 180)
        self.playerService.updateTrackMetadata(
            title: "Unexpected Song",
            artist: "Random Artist",
            thumbnailUrl: "",
            videoId: "unexpected"
        )

        #expect(self.playerService.state == .ended)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
    }

    @Test("Unexpected mid-track autoplay is corrected after playback confirmation")
    func unexpectedMidTrackAutoplayIsCorrected() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.updateTrackMetadata(
            title: "Song 2",
            artist: "",
            thumbnailUrl: "",
            videoId: "v2"
        )

        #expect(self.playerService.isKasetInitiatedPlayback == false)

        self.playerService.updateTrackMetadata(
            title: "Best Song Ever",
            artist: "One Direction",
            thumbnailUrl: "",
            videoId: "unexpected"
        )

        try? await Task.sleep(for: .milliseconds(100))

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.currentTrack?.title == "Song 2")
    }

    @Test("Observed in-queue track realigns current index")
    func observedInQueueTrackRealignsCurrentIndex() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.updateTrackMetadata(
            title: "Song 1",
            artist: "",
            thumbnailUrl: "",
            videoId: "v1"
        )

        self.playerService.updateTrackMetadata(
            title: "Song 3",
            artist: "",
            thumbnailUrl: "",
            videoId: "v3"
        )

        #expect(self.playerService.currentIndex == 2)
        #expect(self.playerService.currentTrack?.videoId == "v3")
        #expect(self.playerService.currentTrack?.title == "Song 3")
    }

    @Test("Track end wraps to the first queue song when repeat all is enabled")
    func trackEndWrapsToStartWhenRepeatAllIsEnabled() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.cycleRepeatMode()
        await self.playerService.handleTrackEnded(observedVideoId: "v2")

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.currentTrack?.title == "Song 1")
    }

    @Test("Track end still wraps when repeat all already reports the first queue song")
    func trackEndWrapsToStartWhenRepeatAllReportsWrappedSong() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.cycleRepeatMode()
        await self.playerService.handleTrackEnded(observedVideoId: "v1")

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.currentTrack?.title == "Song 1")
    }

    @Test("Track end advances native queue before Web autoplay can take over")
    func trackEndAdvancesNativeQueueImmediately() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)
        await self.playerService.handleTrackEnded(observedVideoId: "v1")

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.currentTrack?.title == "Song 2")
    }

    @Test("Stale track-ended events do not double-advance the queue")
    func staleTrackEndedEventIsIgnored() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)
        await self.playerService.handleTrackEnded(observedVideoId: "v1")
        await self.playerService.handleTrackEnded(observedVideoId: "v1")

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
    }

    @Test("Stale repeat-all track-ended events do not skip queue items")
    func staleRepeatAllTrackEndedEventIsIgnored() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.cycleRepeatMode()
        await self.playerService.handleTrackEnded(observedVideoId: "v1")
        await self.playerService.handleTrackEnded(observedVideoId: "v1")

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
    }
}
