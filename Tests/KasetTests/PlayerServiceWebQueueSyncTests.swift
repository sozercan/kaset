import Foundation
import Testing
@testable import Kaset

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

    @Test("Next with shuffle and repeat one still picks random tracks (shuffle wins over repeat one for Next)")
    func nextWithShuffleAndRepeatOneUsesShuffle() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.toggleShuffle()
        #expect(self.playerService.shuffleEnabled == true)

        self.playerService.cycleRepeatMode()
        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .one)

        var sawNonStartIndex = false
        for _ in 0 ..< 18 {
            await self.playerService.next()
            if self.playerService.currentIndex != 1 {
                sawNonStartIndex = true
                break
            }
        }
        #expect(sawNonStartIndex)
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

    @Test("Next with shuffle picks random song from queue")
    func nextWithShufflePicksFromQueue() async {
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

        // Call next multiple times and verify we always pick from the queue
        let validVideoIds = Set(songs.map(\.videoId))
        for _ in 0 ..< 10 {
            await self.playerService.next()
            // Verify the current track is from our queue
            #expect(validVideoIds.contains(self.playerService.currentTrack?.videoId ?? ""), "Shuffle should only pick songs from the queue")
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
