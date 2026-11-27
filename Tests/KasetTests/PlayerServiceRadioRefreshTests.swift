import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct PlayerServiceRadioRefreshTests {
    var playerService: PlayerService
    var mockClient: MockYTMusicClient

    init() {
        UserDefaults.standard.removeObject(forKey: "kaset.saved.queue")
        UserDefaults.standard.removeObject(forKey: "kaset.saved.queueIndex")
        UserDefaults.standard.removeObject(forKey: "kaset.saved.playbackSession")
        SingletonPlayerWebView.shared.currentVideoId = nil

        self.mockClient = MockYTMusicClient()
        self.playerService = PlayerService()
        self.playerService.setYTMusicClient(self.mockClient)
    }

    @Test("Refreshing radio preserves playback and replaces upcoming songs")
    func refreshCurrentSongRadio() async {
        let songs = TestFixtures.makeSongs(count: 5)
        let seed = songs[1]
        await self.playerService.playQueue(Array(songs.prefix(3)), startingAt: 1)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 42, duration: 240)
        self.playerService.pendingPlayVideoId = nil
        let prefixIDs = self.playerService.queueEntryIDs.prefix(2)

        for next in songs.suffix(2) {
            self.mockClient.radioQueueSongs[seed.videoId] = [seed, next]
            await self.playerService.startRadio(song: seed)

            #expect(self.playerService.queueEntryIDs.prefix(2) == prefixIDs)
            #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, seed.videoId, next.videoId])
            #expect(self.playerService.progress == 42)
            #expect(self.playerService.pendingPlayVideoId == nil)
        }
    }

    @Test("Selecting the paused current song resumes it and refreshes radio")
    func pausedCurrentSongRadioResumes() async {
        let songs = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(Array(songs.prefix(2)), startingAt: 0)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 42, duration: 240)
        self.playerService.pendingPlayVideoId = nil
        await self.playerService.pause()
        #expect(self.playerService.state == .paused)
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], songs[2]]

        await self.playerService.startRadio(song: songs[0])

        #expect(self.playerService.shouldResumeAfterInterruption)
        #expect(!self.playerService.isExplicitPauseIntentActive)
        #expect(self.playerService.progress == 42)
        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, songs[2].videoId])
    }

    @Test("Starting radio for a different seed starts its playback and replaces the queue")
    func differentSeedRadio() async {
        let songs = TestFixtures.makeSongs(count: 4)
        await self.playerService.playQueue(Array(songs.prefix(2)), startingAt: 0)
        self.mockClient.radioQueueSongs[songs[2].videoId] = Array(songs.suffix(2))

        await self.playerService.startRadio(song: songs[2])

        #expect(self.playerService.currentTrack?.videoId == songs[2].videoId)
        #expect(self.playerService.pendingPlayVideoId == songs[2].videoId)
        #expect(self.playerService.queue.map(\.videoId) == songs.suffix(2).map(\.videoId))
    }

    @Test("An empty or failed radio refresh preserves the queue and playback", arguments: [false, true])
    func unavailableRadioRefresh(fails: Bool) async {
        let songs = TestFixtures.makeSongs(count: 2)
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 42, duration: 240)
        self.playerService.pendingPlayVideoId = nil
        let entryIDs = self.playerService.queueEntryIDs
        if fails {
            self.mockClient.radioQueueErrors[songs[0].videoId] = URLError(.timedOut)
        }

        await self.playerService.startRadio(song: songs[0])

        #expect(self.playerService.queueEntryIDs == entryIDs)
        #expect(self.playerService.currentTrack?.videoId == songs[0].videoId)
        #expect(self.playerService.state == .playing)
        #expect(self.playerService.progress == 42)
        #expect(self.playerService.pendingPlayVideoId == nil)
    }

    @Test(
        "An empty or failed radio refresh skips the Smart Shuffle fill",
        arguments: [false, true]
    )
    func unavailableRadioRefreshSkipsSmartShuffleFill(fails: Bool) async {
        let songs = TestFixtures.makeSongs(count: 3)
        let recommended = TestFixtures.makeSong(id: "rec-1")
        self.playerService.smartShuffleFeatureEnabled = { true }
        self.playerService.smartShuffleConfigProvider = {
            PlayerService.SmartShuffleConfig(suggestEveryN: 1, burst: 1, suggestionsAhead: 1)
        }
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.shuffleMode = .smart
        self.mockClient.radioQueueSongs[songs[1].videoId] = [songs[1], recommended]
        if fails {
            self.mockClient.radioQueueErrors[songs[0].videoId] = URLError(.timedOut)
        }
        let originalEntries = self.playerService.queueEntries

        await self.playerService.startRadio(song: songs[0])

        #expect(self.playerService.queueEntries == originalEntries)
        #expect(self.mockClient.getRadioQueueVideoIds == [songs[0].videoId])
    }

    @Test("A queue edit during a radio refresh wins")
    func editDuringRadioRefresh() async {
        let songs = TestFixtures.makeSongs(count: 4)
        await self.playerService.playQueue(Array(songs.prefix(3)), startingAt: 0)
        let retainedIDs = Array(self.playerService.queueEntryIDs.prefix(2))
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[3]]
        self.mockClient.beforeRadioQueueReturn = { [playerService] _ in
            await playerService.removeFromQueue(at: 2)
        }

        await self.playerService.startRadio(song: songs[0])

        #expect(self.playerService.queueEntryIDs == retainedIDs)
    }

    @Test("Seeking during a radio refresh keeps the new position and applies recommendations")
    func seekDuringRadioRefresh() async {
        let songs = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(Array(songs.prefix(2)), startingAt: 0)
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[2]]
        self.mockClient.beforeRadioQueueReturn = { [playerService] _ in
            await playerService.seek(to: 42)
        }

        await self.playerService.startRadio(song: songs[0])

        #expect(self.playerService.progress == 42)
        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, songs[2].videoId])
    }

    @Test("Same-song radio refresh keeps admitting a prior track-end event")
    func sameSongRadioRefreshAdmitsPriorTrackEnd() async throws {
        let songs = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(Array(songs.prefix(2)), startingAt: 0)
        let priorIntent = self.playerService.currentMusicPlaybackIntent
        let occurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], songs[2]]

        await self.playerService.startRadio(song: songs[0])
        let emittedAt = self.playerService.musicPlaybackIntentIssuedAtMilliseconds - 1

        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, songs[2].videoId])
        #expect(!self.playerService.acceptsMusicBridgeEvent(
            intent: priorIntent,
            eventIssuedAtMilliseconds: emittedAt
        ))
        #expect(self.playerService.acceptsMusicTerminalBridgeEvent(
            intent: priorIntent,
            eventIssuedAtMilliseconds: emittedAt
        ))
        #expect(self.playerService.acceptsMusicTerminalBridgeEvent(
            intent: self.playerService.currentMusicPlaybackIntent,
            eventIssuedAtMilliseconds: emittedAt
        ))

        await self.playerService.handleTrackEnded(
            observedVideoId: songs[0].videoId,
            playbackOccurrence: occurrence,
            intent: priorIntent
        )

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == songs[2].videoId)
    }

    @Test("Start Radio on detached playback restarts the song with radio")
    func startRadioOnDetachedPlaybackRestarts() async {
        let songs = TestFixtures.makeSongs(count: 2)
        await self.playerService.play(videoId: songs[0].videoId)
        self.playerService.pendingPlayVideoId = nil
        #expect(self.playerService.queueEntryIDOwningCurrentPlayback == nil)
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], songs[1]]

        await self.playerService.startRadio(song: songs[0])

        #expect(self.playerService.pendingPlayVideoId == songs[0].videoId)
        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, songs[1].videoId])
    }

    @Test("Start Radio on a later duplicate of the playing song restarts from that row")
    func startRadioOnDuplicateRowRestarts() async {
        let songs = TestFixtures.makeSongs(count: 2)
        await self.playerService.playQueue([songs[0], songs[1], songs[0]], startingAt: 0)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 42, duration: 240)
        self.playerService.pendingPlayVideoId = nil
        let duplicateEntryID = self.playerService.queueEntryIDs[2]
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], songs[1]]

        await self.playerService.startRadio(song: songs[0], queueEntryID: duplicateEntryID)

        #expect(self.playerService.pendingPlayVideoId == songs[0].videoId)
        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, songs[1].videoId])
    }

    @Test("Start Radio on detached playback keeps prior track-end events blocked")
    func detachedStartRadioIntentBlocksPriorTerminalEvents() async {
        let songs = TestFixtures.makeSongs(count: 1)
        await self.playerService.play(videoId: songs[0].videoId)

        _ = self.playerService.beginRadioPlaybackIntent(for: songs[0])

        #expect(!self.playerService.musicPlaybackIntentAcceptsPriorTerminalEvent)
    }

    @Test("Different-song radio rejects a prior track-end event")
    func differentSongRadioRejectsPriorTrackEnd() async throws {
        let songs = TestFixtures.makeSongs(count: 4)
        await self.playerService.playQueue(Array(songs.prefix(2)), startingAt: 0)
        let priorIntent = self.playerService.currentMusicPlaybackIntent
        let occurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)
        self.mockClient.radioQueueSongs[songs[2].videoId] = [songs[2], songs[3]]

        await self.playerService.startRadio(song: songs[2])
        let emittedAt = self.playerService.musicPlaybackIntentIssuedAtMilliseconds - 1

        #expect(!self.playerService.acceptsMusicTerminalBridgeEvent(
            intent: priorIntent,
            eventIssuedAtMilliseconds: emittedAt
        ))
        #expect(!self.playerService.acceptsMusicTerminalBridgeEvent(
            intent: self.playerService.currentMusicPlaybackIntent,
            eventIssuedAtMilliseconds: emittedAt
        ))

        await self.playerService.handleTrackEnded(
            observedVideoId: songs[0].videoId,
            playbackOccurrence: occurrence,
            intent: priorIntent
        )

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == songs[2].videoId)
    }

    @Test("Playing the current song restarts it with a new radio queue")
    func playingCurrentSongRestartsIt() async {
        let songs = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(Array(songs.prefix(2)), startingAt: 0)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 42, duration: 240)
        self.playerService.pendingPlayVideoId = nil
        let entryIDs = self.playerService.queueEntryIDs
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], songs[2]]

        await self.playerService.playWithRadio(song: songs[0])

        #expect(self.playerService.pendingPlayVideoId == songs[0].videoId)
        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, songs[2].videoId])
        #expect(self.playerService.queueEntryIDs.first != entryIDs.first)
    }
}
