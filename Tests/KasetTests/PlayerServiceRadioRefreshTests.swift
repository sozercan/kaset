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

    @Test("Start Radio while a track end waits on queue maintenance still advances into the radio queue")
    func startRadioDuringTrackEndMaintenanceAdvances() async throws {
        let songs = TestFixtures.makeSongs(count: 2)
        await self.playerService.playQueue([songs[0]], startingAt: 0)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 239, duration: 240)
        let priorIntent = self.playerService.currentMusicPlaybackIntent
        let occurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], songs[1]]

        let maintenanceGate = AsyncGate()
        let maintenanceTask = Task { @MainActor in await maintenanceGate.wait() }
        self.playerService.nativeQueueMaintenanceTask = maintenanceTask

        let trackEnd = Task { @MainActor [playerService] in
            await playerService.handleTrackEnded(
                observedVideoId: songs[0].videoId,
                playbackOccurrence: occurrence,
                intent: priorIntent
            )
        }
        for _ in 0 ..< 1000 where self.playerService.nativeQueueMaintenanceWaiters.isEmpty {
            await Task.yield()
        }
        #expect(!self.playerService.nativeQueueMaintenanceWaiters.isEmpty)

        await self.playerService.startRadio(song: songs[0])
        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, songs[1].videoId])

        await maintenanceGate.open()
        await maintenanceTask.value
        self.playerService.clearNativeQueueMaintenance()
        await trackEnd.value

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == songs[1].videoId)
    }

    @Test("An older Start Radio response that lands first does not replace a newer refresh")
    func olderStartRadioResponseYieldsToNewerRefresh() async {
        let songs = TestFixtures.makeSongs(count: 1)
        let olderRecommendation = TestFixtures.makeSong(id: "rec-older")
        let newerRecommendation = TestFixtures.makeSong(id: "rec-newer")
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 42, duration: 240)

        let olderGate = AsyncGate()
        self.mockClient.getRadioQueueGate = olderGate
        let olderRefresh = Task { @MainActor [playerService] in
            await playerService.startRadio(song: songs[0])
        }
        for _ in 0 ..< 1000 where self.mockClient.getRadioQueueVideoIds.count < 1 {
            await Task.yield()
        }
        guard self.mockClient.getRadioQueueVideoIds.count == 1 else {
            await olderGate.open()
            await olderRefresh.value
            Issue.record("The older radio request never reached the mock client")
            return
        }

        let newerGate = AsyncGate()
        self.mockClient.getRadioQueueGate = newerGate
        let newerRefresh = Task { @MainActor [playerService] in
            await playerService.startRadio(song: songs[0])
        }
        for _ in 0 ..< 1000 where self.mockClient.getRadioQueueVideoIds.count < 2 {
            await Task.yield()
        }
        #expect(self.mockClient.getRadioQueueVideoIds.count == 2)

        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], olderRecommendation]
        await olderGate.open()
        await olderRefresh.value

        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], newerRecommendation]
        await newerGate.open()
        await newerRefresh.value

        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, newerRecommendation.videoId])
    }

    @Test("Selecting Start Radio again discards an older response before the new refresh runs")
    func newStartRadioSelectionDiscardsOlderResponse() async {
        let songs = TestFixtures.makeSongs(count: 1)
        let olderRecommendation = TestFixtures.makeSong(id: "rec-older")
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 42, duration: 240)
        let entryIDs = self.playerService.queueEntryIDs

        let olderGate = AsyncGate()
        self.mockClient.getRadioQueueGate = olderGate
        let olderRefresh = Task { @MainActor [playerService] in
            await playerService.startRadio(song: songs[0])
        }
        for _ in 0 ..< 1000 where self.mockClient.getRadioQueueVideoIds.isEmpty {
            await Task.yield()
        }

        _ = self.playerService.beginRadioPlaybackIntent(for: songs[0])
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], olderRecommendation]
        await olderGate.open()
        await olderRefresh.value

        #expect(self.playerService.queueEntryIDs == entryIDs)
    }

    @Test("An automatic radio merge during Start Radio does not count as a queue edit")
    func automaticRadioMergeDuringStartRadioStillApplies() async {
        let songs = TestFixtures.makeSongs(count: 1)
        let automaticRecommendation = TestFixtures.makeSong(id: "rec-automatic")
        let startRadioRecommendation = TestFixtures.makeSong(id: "rec-start-radio")
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 42, duration: 240)
        self.mockClient.beforeRadioQueueReturn = { [playerService, mockClient] videoId in
            await MainActor.run {
                mockClient.beforeRadioQueueReturn = nil
                mockClient.radioQueueSongs[videoId] = [songs[0], automaticRecommendation]
            }
            await playerService.fetchAndApplyRadioQueue(for: videoId)
            await MainActor.run {
                mockClient.radioQueueSongs[videoId] = [songs[0], startRadioRecommendation]
            }
        }

        await self.playerService.startRadio(song: songs[0])

        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, startRadioRecommendation.videoId])
    }

    @Test("When the queue ends while Start Radio is fetching, playback continues into the radio")
    func queueEndDuringStartRadioFetchContinues() async throws {
        let songs = TestFixtures.makeSongs(count: 1)
        let recommended = TestFixtures.makeSong(id: "rec-1")
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 239, duration: 240)
        let priorIntent = self.playerService.currentMusicPlaybackIntent
        let occurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)

        let radioGate = AsyncGate()
        self.mockClient.getRadioQueueGate = radioGate
        let refresh = Task { @MainActor [playerService] in
            await playerService.startRadio(song: songs[0])
        }
        for _ in 0 ..< 1000 where self.mockClient.getRadioQueueVideoIds.isEmpty {
            await Task.yield()
        }
        guard self.mockClient.getRadioQueueVideoIds.count == 1 else {
            await radioGate.open()
            await refresh.value
            Issue.record("The Start Radio request never reached the mock client")
            return
        }

        self.mockClient.getRadioQueueGate = nil
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], recommended]
        await self.playerService.handleTrackEnded(
            observedVideoId: songs[0].videoId,
            playbackOccurrence: occurrence,
            intent: priorIntent
        )
        #expect(self.playerService.state == .ended)

        await radioGate.open()
        await refresh.value

        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, recommended.videoId])
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == recommended.videoId)
    }

    @Test("When the song ends during Start Radio and playback advances, the radio follows the new song")
    func advanceDuringStartRadioFetchKeepsRadio() async throws {
        let songs = TestFixtures.makeSongs(count: 3)
        let recommended = TestFixtures.makeSong(id: "rec-1")
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 239, duration: 240)
        let priorIntent = self.playerService.currentMusicPlaybackIntent
        let occurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)
        let entryIDs = self.playerService.queueEntryIDs

        let radioGate = AsyncGate()
        self.mockClient.getRadioQueueGate = radioGate
        let refresh = Task { @MainActor [playerService] in
            await playerService.startRadio(song: songs[0])
        }
        for _ in 0 ..< 1000 where self.mockClient.getRadioQueueVideoIds.isEmpty {
            await Task.yield()
        }
        guard self.mockClient.getRadioQueueVideoIds.count == 1 else {
            await radioGate.open()
            await refresh.value
            Issue.record("The Start Radio request never reached the mock client")
            return
        }

        self.mockClient.getRadioQueueGate = nil
        await self.playerService.handleTrackEnded(
            observedVideoId: songs[0].videoId,
            playbackOccurrence: occurrence,
            intent: priorIntent
        )
        #expect(self.playerService.currentTrack?.videoId == songs[1].videoId)

        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], recommended]
        await radioGate.open()
        await refresh.value

        #expect(Array(self.playerService.queueEntryIDs.prefix(2)) == Array(entryIDs.prefix(2)))
        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, songs[1].videoId, recommended.videoId])
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == songs[1].videoId)
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

    @Test("When the song playback moved to also ends during Start Radio, playback continues into the radio")
    func advancedSongEndsDuringStartRadioFetchContinues() async throws {
        let songs = TestFixtures.makeSongs(count: 2)
        let recommended = TestFixtures.makeSong(id: "rec-1")
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 239, duration: 240)
        let firstIntent = self.playerService.currentMusicPlaybackIntent
        let firstOccurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)

        let radioGate = AsyncGate()
        self.mockClient.getRadioQueueGate = radioGate
        let refresh = Task { @MainActor [playerService] in
            await playerService.startRadio(song: songs[0])
        }
        for _ in 0 ..< 1000 where self.mockClient.getRadioQueueVideoIds.isEmpty {
            await Task.yield()
        }
        guard self.mockClient.getRadioQueueVideoIds.count == 1 else {
            await radioGate.open()
            await refresh.value
            Issue.record("The Start Radio request never reached the mock client")
            return
        }

        self.mockClient.getRadioQueueGate = nil
        await self.playerService.handleTrackEnded(
            observedVideoId: songs[0].videoId,
            playbackOccurrence: firstOccurrence,
            intent: firstIntent
        )
        #expect(self.playerService.currentTrack?.videoId == songs[1].videoId)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 239, duration: 240)
        let secondIntent = self.playerService.currentMusicPlaybackIntent
        let secondOccurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)
        await self.playerService.handleTrackEnded(
            observedVideoId: songs[1].videoId,
            playbackOccurrence: secondOccurrence,
            intent: secondIntent
        )
        #expect(self.playerService.state == .ended)

        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], recommended]
        await radioGate.open()
        await refresh.value

        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, songs[1].videoId, recommended.videoId])
        #expect(self.playerService.currentTrack?.videoId == recommended.videoId)
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

    @Test("A pause after the queue ends during Start Radio keeps playback stopped")
    func pauseAfterQueueEndDuringStartRadioStaysStopped() async throws {
        let songs = TestFixtures.makeSongs(count: 1)
        let recommended = TestFixtures.makeSong(id: "rec-1")
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 239, duration: 240)
        let priorIntent = self.playerService.currentMusicPlaybackIntent
        let occurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)

        let radioGate = AsyncGate()
        self.mockClient.getRadioQueueGate = radioGate
        let refresh = Task { @MainActor [playerService] in
            await playerService.startRadio(song: songs[0])
        }
        for _ in 0 ..< 1000 where self.mockClient.getRadioQueueVideoIds.isEmpty {
            await Task.yield()
        }
        guard self.mockClient.getRadioQueueVideoIds.count == 1 else {
            await radioGate.open()
            await refresh.value
            Issue.record("The Start Radio request never reached the mock client")
            return
        }

        self.mockClient.getRadioQueueGate = nil
        await self.playerService.handleTrackEnded(
            observedVideoId: songs[0].videoId,
            playbackOccurrence: occurrence,
            intent: priorIntent
        )
        await self.playerService.pause()

        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], recommended]
        await radioGate.open()
        await refresh.value

        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, recommended.videoId])
        #expect(self.playerService.currentTrack?.videoId == songs[0].videoId)
        #expect(self.playerService.pendingPlayVideoId != recommended.videoId)
    }

    @Test("Smart Shuffle still fills when playback moves forward during Start Radio")
    func advanceDuringSmartShuffleStartRadioFills() async throws {
        let songs = TestFixtures.makeSongs(count: 3)
        let recommended = TestFixtures.makeSong(id: "rec-1")
        let suggested = TestFixtures.makeSong(id: "suggested-1")
        self.playerService.smartShuffleFeatureEnabled = { true }
        self.playerService.smartShuffleConfigProvider = {
            PlayerService.SmartShuffleConfig(suggestEveryN: 1, burst: 1, suggestionsAhead: 1)
        }
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.shuffleMode = .smart
        self.playerService.updatePlaybackState(isPlaying: true, progress: 239, duration: 240)
        let priorIntent = self.playerService.currentMusicPlaybackIntent
        let occurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)

        let radioGate = AsyncGate()
        self.mockClient.getRadioQueueGate = radioGate
        let refresh = Task { @MainActor [playerService] in
            await playerService.startRadio(song: songs[0])
        }
        for _ in 0 ..< 1000 where self.mockClient.getRadioQueueVideoIds.isEmpty {
            await Task.yield()
        }
        guard self.mockClient.getRadioQueueVideoIds.count == 1 else {
            await radioGate.open()
            await refresh.value
            Issue.record("The Start Radio request never reached the mock client")
            return
        }

        self.mockClient.getRadioQueueGate = nil
        let advancedTrack = self.playerService.queue[safe: self.playerService.currentIndex + 1]
        await self.playerService.handleTrackEnded(
            observedVideoId: songs[0].videoId,
            playbackOccurrence: occurrence,
            intent: priorIntent
        )
        #expect(self.playerService.currentTrack?.videoId == advancedTrack?.videoId)

        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], recommended]
        for song in Array(songs.dropFirst()) + [recommended] {
            self.mockClient.radioQueueSongs[song.videoId] = [suggested]
        }
        await radioGate.open()
        await refresh.value

        #expect(self.playerService.queue.contains { $0.videoId == recommended.videoId })
        #expect(self.playerService.queueEntries.contains {
            $0.song.videoId == suggested.videoId && $0.source == .suggested
        })
    }

    @Test("Start Radio survives a shuffled playlist load finishing after playback moves forward")
    func shuffledLoadEndAfterAdvanceKeepsRadio() async throws {
        let songs = TestFixtures.makeSongs(count: 4)
        let recommended = TestFixtures.makeSong(id: "rec-1")
        await self.playerService.playQueue(Array(songs.prefix(3)), startingAt: 0)
        self.playerService.shuffleMode = .on
        let loadGeneration = self.playerService.beginQueueLoading()
        self.playerService.updatePlaybackState(isPlaying: true, progress: 239, duration: 240)
        let priorIntent = self.playerService.currentMusicPlaybackIntent
        let occurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)

        let radioGate = AsyncGate()
        self.mockClient.getRadioQueueGate = radioGate
        let refresh = Task { @MainActor [playerService] in
            await playerService.startRadio(song: songs[0])
        }
        for _ in 0 ..< 1000 where self.mockClient.getRadioQueueVideoIds.isEmpty {
            await Task.yield()
        }
        guard self.mockClient.getRadioQueueVideoIds.count == 1 else {
            await radioGate.open()
            await refresh.value
            Issue.record("The Start Radio request never reached the mock client")
            return
        }

        self.mockClient.getRadioQueueGate = nil
        await self.playerService.handleTrackEnded(
            observedVideoId: songs[0].videoId,
            playbackOccurrence: occurrence,
            intent: priorIntent
        )
        let advancedVideoId = try #require(self.playerService.currentTrack?.videoId)
        #expect(advancedVideoId != songs[0].videoId)
        await self.playerService.appendOriginalTracks([songs[3]])
        await self.playerService.endQueueLoading(loadGeneration)
        #expect(self.playerService.queueEntries.firstIndex { $0.song.videoId == advancedVideoId } == 0)

        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], recommended]
        await radioGate.open()
        await refresh.value

        #expect(self.playerService.currentTrack?.videoId == advancedVideoId)
        #expect(self.playerService.queue.first?.videoId == advancedVideoId)
        #expect(self.playerService.queue.contains { $0.videoId == recommended.videoId })
    }

    @Test("Start Radio applies after playback advances into a song appended during the fetch")
    func advanceIntoAppendedSongDuringStartRadioKeepsRadio() async throws {
        let songs = TestFixtures.makeSongs(count: 2)
        let recommended = TestFixtures.makeSong(id: "rec-1")
        await self.playerService.playQueue([songs[0]], startingAt: 0)
        let loadGeneration = self.playerService.beginQueueLoading()
        self.playerService.updatePlaybackState(isPlaying: true, progress: 239, duration: 240)
        let priorIntent = self.playerService.currentMusicPlaybackIntent
        let occurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)

        let radioGate = AsyncGate()
        self.mockClient.getRadioQueueGate = radioGate
        let refresh = Task { @MainActor [playerService] in
            await playerService.startRadio(song: songs[0])
        }
        for _ in 0 ..< 1000 where self.mockClient.getRadioQueueVideoIds.isEmpty {
            await Task.yield()
        }
        guard self.mockClient.getRadioQueueVideoIds.count == 1 else {
            await radioGate.open()
            await refresh.value
            Issue.record("The Start Radio request never reached the mock client")
            return
        }

        self.mockClient.getRadioQueueGate = nil
        await self.playerService.appendOriginalTracks([songs[1]])
        await self.playerService.endQueueLoading(loadGeneration)
        await self.playerService.handleTrackEnded(
            observedVideoId: songs[0].videoId,
            playbackOccurrence: occurrence,
            intent: priorIntent
        )
        #expect(self.playerService.currentTrack?.videoId == songs[1].videoId)

        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], recommended]
        await radioGate.open()
        await refresh.value

        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, songs[1].videoId, recommended.videoId])
        #expect(self.playerService.currentTrack?.videoId == songs[1].videoId)
    }

    @Test("Going back to an earlier song during Start Radio keeps the radio after the seed")
    func previousDuringStartRadioKeepsRadioAfterSeed() async {
        let songs = TestFixtures.makeSongs(count: 2)
        let recommended = TestFixtures.makeSong(id: "rec-1")
        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 1, duration: 240)
        let entryIDs = self.playerService.queueEntryIDs

        let radioGate = AsyncGate()
        self.mockClient.getRadioQueueGate = radioGate
        let refresh = Task { @MainActor [playerService] in
            await playerService.startRadio(song: songs[1])
        }
        for _ in 0 ..< 1000 where self.mockClient.getRadioQueueVideoIds.isEmpty {
            await Task.yield()
        }
        guard self.mockClient.getRadioQueueVideoIds.count == 1 else {
            await radioGate.open()
            await refresh.value
            Issue.record("The Start Radio request never reached the mock client")
            return
        }

        self.mockClient.getRadioQueueGate = nil
        await self.playerService.previous()
        #expect(self.playerService.currentTrack?.videoId == songs[0].videoId)

        self.mockClient.radioQueueSongs[songs[1].videoId] = [songs[1], recommended]
        await radioGate.open()
        await refresh.value

        #expect(Array(self.playerService.queueEntryIDs.prefix(2)) == entryIDs)
        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, songs[1].videoId, recommended.videoId])
        #expect(self.playerService.currentTrack?.videoId == songs[0].videoId)
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
