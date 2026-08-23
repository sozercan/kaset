import Foundation
import Testing
@testable import Kaset

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
        self.playerService.lastNonAdContentProgress = 179
        self.playerService.lastNonAdContentVideoId = "v1"

        await self.playerService.handleTrackEnded(observedVideoId: "v1")

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.pendingPlayVideoId == "v1")
        #expect(self.playerService.lastNonAdContentProgress == 0)
        #expect(self.playerService.lastNonAdContentVideoId == nil)
        #expect(self.playerService.shouldResumeAfterInterruption)
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

    @Test("Near-end metadata transition is not advanced again by a late ended callback")
    func nearEndMetadataThenLateEndedDoesNotDoubleAdvance() async {
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
            title: "Song 2",
            artist: "",
            thumbnailUrl: "",
            videoId: "v2",
            playbackOccurrence: outgoingOccurrence
        )
        #expect(self.playerService.currentIndex == 1)
        let incomingOccurrence = MusicPlaybackOccurrence.web(
            documentGeneration: 7,
            mediaGeneration: 2,
            nativeGeneration: self.playerService.currentNativeMusicPlaybackGeneration,
            videoId: "v2"
        )
        _ = self.playerService.bindWebMusicPlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 2,
            nativeGeneration: incomingOccurrence.nativeGeneration,
            videoId: "v2"
        )

        await self.playerService.handleTrackEnded(
            observedVideoId: "v1",
            playbackOccurrence: outgoingOccurrence
        )

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")

        await self.playerService.handleTrackEnded(
            observedVideoId: "v2",
            playbackOccurrence: incomingOccurrence
        )

        #expect(self.playerService.currentIndex == 2)
        #expect(self.playerService.currentTrack?.videoId == "v3")
    }

    @Test("Duplicate ended callback replays repeat one only once")
    func duplicateEndedCallbackReplaysRepeatOneOnlyOnce() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.cycleRepeatMode()
        self.playerService.cycleRepeatMode()
        let endedOccurrence = self.playerService.currentMusicPlaybackOccurrence

        await self.playerService.handleTrackEnded(
            observedVideoId: "v1",
            playbackOccurrence: endedOccurrence
        )
        let replayOccurrence = self.playerService.currentMusicPlaybackOccurrence
        await self.playerService.handleTrackEnded(
            observedVideoId: "v1",
            playbackOccurrence: endedOccurrence
        )

        #expect(self.playerService.currentIndex == 0)
        #expect(replayOccurrence != endedOccurrence)
        #expect(self.playerService.currentMusicPlaybackOccurrence == replayOccurrence)
    }

    @Test("Duplicate ended callback does not skip a repeated video ID in repeat all")
    func duplicateEndedCallbackDoesNotSkipRepeatedVideoIdInRepeatAll() async {
        let songs = [
            Song(id: "1a", title: "Song 1A", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "1b", title: "Song 1B", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.cycleRepeatMode()
        let endedOccurrence = self.playerService.currentMusicPlaybackOccurrence

        await self.playerService.handleTrackEnded(
            observedVideoId: "v1",
            playbackOccurrence: endedOccurrence
        )
        await self.playerService.handleTrackEnded(
            observedVideoId: "v1",
            playbackOccurrence: endedOccurrence
        )

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.title == "Song 1B")
    }

    @Test("Duplicate ended callback replays no-queue repeat one only once")
    func duplicateEndedCallbackReplaysNoQueueRepeatOneOnlyOnce() async {
        let song = Song(
            id: "solo",
            title: "Solo",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "solo-video"
        )
        await self.playerService.play(song: song)
        self.playerService.cycleRepeatMode()
        self.playerService.cycleRepeatMode()
        let endedOccurrence = self.playerService.currentMusicPlaybackOccurrence

        await self.playerService.handleTrackEnded(
            observedVideoId: "solo-video",
            playbackOccurrence: endedOccurrence
        )
        let replayOccurrence = self.playerService.currentMusicPlaybackOccurrence
        await self.playerService.handleTrackEnded(
            observedVideoId: "solo-video",
            playbackOccurrence: endedOccurrence
        )

        #expect(self.playerService.queue.isEmpty)
        #expect(replayOccurrence != endedOccurrence)
        #expect(self.playerService.currentMusicPlaybackOccurrence == replayOccurrence)
        #expect(self.playerService.state != .ended)
    }

    @Test("A later observer occurrence can end after the previous occurrence was consumed")
    func laterObserverOccurrenceCanEnd() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        let firstOccurrence = self.playerService.bindWebMusicPlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1,
            nativeGeneration: self.playerService.currentNativeMusicPlaybackGeneration,
            videoId: "v1"
        )

        await self.playerService.handleTrackEnded(
            observedVideoId: "v1",
            playbackOccurrence: firstOccurrence
        )
        let secondOccurrence = self.playerService.bindWebMusicPlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 2,
            nativeGeneration: self.playerService.currentNativeMusicPlaybackGeneration,
            videoId: "v2"
        )
        await self.playerService.handleTrackEnded(
            observedVideoId: "v2",
            playbackOccurrence: secondOccurrence
        )

        #expect(self.playerService.currentIndex == 2)
        #expect(self.playerService.currentTrack?.videoId == "v3")
    }

    @Test("Near-end state does not bind an incoming occurrence before metadata handoff")
    func nearEndDefersIncomingOccurrenceBinding() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        let nativeGeneration = self.playerService.currentNativeMusicPlaybackGeneration
        let outgoingOccurrence = self.playerService.bindWebMusicPlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1,
            nativeGeneration: nativeGeneration,
            videoId: "v1"
        )
        self.playerService.songNearingEnd = true

        let incomingOccurrence = self.playerService.bindWebMusicPlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 2,
            nativeGeneration: nativeGeneration,
            videoId: "v2"
        )

        #expect(incomingOccurrence == nil)
        #expect(self.playerService.currentMusicPlaybackOccurrence == outgoingOccurrence)
    }

    @Test("Music occurrence identity can refine its video ID without becoming newer")
    func occurrenceVideoIdentityCanRefine() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        let nativeGeneration = self.playerService.currentNativeMusicPlaybackGeneration
        let provisional = self.playerService.bindWebMusicPlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1,
            nativeGeneration: nativeGeneration,
            videoId: nil
        )
        let refined = self.playerService.bindWebMusicPlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1,
            nativeGeneration: nativeGeneration,
            videoId: "v1"
        )

        #expect(provisional == refined)
        #expect(self.playerService.currentMusicPlaybackOccurrence?.videoId == "v1")
    }

    @Test("A claimed native occurrence consumes its matching first Web occurrence")
    func claimedNativeOccurrenceTransfersToMatchingWebOccurrence() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        let nativeOccurrence = self.playerService.currentMusicPlaybackOccurrence

        #expect(self.playerService.claimTerminalMusicPlaybackOccurrence(nativeOccurrence))
        let matchingWebOccurrence = self.playerService.bindWebMusicPlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1,
            nativeGeneration: nativeOccurrence?.nativeGeneration ?? 0,
            videoId: "v1"
        )

        #expect(!self.playerService.claimTerminalMusicPlaybackOccurrence(matchingWebOccurrence))
    }

    @Test("A delayed Web occurrence cannot replace a newer native replay")
    func delayedWebOccurrenceCannotReplaceNativeReplay() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        let endedNativeOccurrence = self.playerService.currentMusicPlaybackOccurrence
        #expect(self.playerService.claimTerminalMusicPlaybackOccurrence(endedNativeOccurrence))

        let replayOccurrence = self.playerService.beginNativeMusicPlaybackOccurrence(videoId: "v1")
        let delayedWebOccurrence = MusicPlaybackOccurrence.web(
            documentGeneration: 7,
            mediaGeneration: 1,
            nativeGeneration: endedNativeOccurrence?.nativeGeneration ?? 0,
            videoId: "v1"
        )

        let boundOccurrence = self.playerService.bindWebMusicPlaybackOccurrence(
            documentGeneration: delayedWebOccurrence.documentGeneration ?? 0,
            mediaGeneration: delayedWebOccurrence.mediaGeneration,
            nativeGeneration: delayedWebOccurrence.nativeGeneration,
            videoId: delayedWebOccurrence.videoId
        )

        #expect(boundOccurrence == nil)
        #expect(!self.playerService.claimTerminalMusicPlaybackOccurrence(delayedWebOccurrence))
        #expect(self.playerService.currentMusicPlaybackOccurrence == replayOccurrence)
    }

    @Test("Manual seek-to-end and a late ended callback share one occurrence")
    func manualSeekToEndThenLateEndedDoesNotDoubleAdvance() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        let endedOccurrence = self.playerService.currentMusicPlaybackOccurrence

        await self.playerService.seek(to: 180)
        await self.playerService.handleTrackEnded(
            observedVideoId: "v1",
            playbackOccurrence: endedOccurrence
        )

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
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
