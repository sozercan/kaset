import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct PlayerServiceStartRadioRaceTests {
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

    @Test("Seeking to the end during Start Radio still continues into the radio")
    func seekToEndDuringStartRadioContinues() async throws {
        let songs = TestFixtures.makeSongs(count: 1)
        let recommended = TestFixtures.makeSong(id: "rec-1")
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 42, duration: 240)

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
        await self.playerService.seek(to: 239)
        let seekIntent = self.playerService.currentMusicPlaybackIntent
        let occurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)
        await self.playerService.handleTrackEnded(
            observedVideoId: songs[0].videoId,
            playbackOccurrence: occurrence,
            intent: seekIntent
        )
        #expect(self.playerService.state == .ended)

        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], recommended]
        await radioGate.open()
        await refresh.value

        #expect(self.playerService.currentTrack?.videoId == recommended.videoId)
    }

    @Test("After the queue ends and reorders during Start Radio, playback starts at the first recommendation")
    func queueEndAndReorderDuringStartRadioStartsRecommendation() async throws {
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
        self.playerService.updatePlaybackState(isPlaying: true, progress: 239, duration: 240)
        let secondIntent = self.playerService.currentMusicPlaybackIntent
        let secondOccurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)
        await self.playerService.handleTrackEnded(
            observedVideoId: songs[1].videoId,
            playbackOccurrence: secondOccurrence,
            intent: secondIntent
        )
        #expect(self.playerService.state == .ended)
        let entries = self.playerService.queueEntries
        self.playerService.applyAutomaticQueueChange {
            self.playerService.setQueue(entries: [entries[1], entries[0]])
        }
        self.playerService.currentIndex = 0

        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], recommended]
        await radioGate.open()
        await refresh.value

        #expect(self.playerService.queue.map(\.videoId) == [songs[1].videoId, songs[0].videoId, recommended.videoId])
        #expect(self.playerService.currentTrack?.videoId == recommended.videoId)
    }

    @Test("An automatic stop after a failed queue advance still lets Start Radio continue")
    func failedQueueAdvanceStopDuringStartRadioContinues() async {
        let songs = TestFixtures.makeSongs(count: 1)
        let recommended = TestFixtures.makeSong(id: "rec-1")
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 239, duration: 240)

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
        await self.playerService.finishPlaybackAfterFailedQueueAdvance(reason: "test")
        #expect(self.playerService.state == .ended)

        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], recommended]
        await radioGate.open()
        await refresh.value

        #expect(self.playerService.currentTrack?.videoId == recommended.videoId)
    }

    @Test("Only explicit pauses advance the explicit pause generation")
    func automaticStopsDoNotCountAsExplicitPauses() async {
        let songs = TestFixtures.makeSongs(count: 1)
        await self.playerService.playQueue(songs, startingAt: 0)
        let generation = self.playerService.explicitPauseGeneration

        await self.playerService.pause(isAutomaticStop: true)
        #expect(self.playerService.explicitPauseGeneration == generation)

        await self.playerService.pause()
        #expect(self.playerService.explicitPauseGeneration == generation + 1)
    }
}
