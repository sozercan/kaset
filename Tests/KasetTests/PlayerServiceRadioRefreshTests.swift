import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct PlayerServiceRadioRefreshQueueLoadTests {
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

    @Test("An empty or failed radio refresh keeps an in-flight playlist load alive", arguments: [false, true])
    func unavailableRadioRefreshKeepsQueueLoad(fails: Bool) async {
        let songs = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(songs, startingAt: 0)
        let generation = self.playerService.beginQueueLoading()
        let entryIDs = self.playerService.queueEntryIDs
        if fails {
            self.mockClient.radioQueueErrors[songs[0].videoId] = URLError(.timedOut)
        }

        await self.playerService.startRadio(song: songs[0])

        #expect(self.playerService.isCurrentQueueLoad(generation))
        #expect(self.playerService.isQueueLoading)
        #expect(self.playerService.queueEntryIDs == entryIDs)
    }

    @Test("An applied radio refresh stops an in-flight playlist load")
    func appliedRadioRefreshStopsQueueLoad() async {
        let songs = TestFixtures.makeSongs(count: 4)
        await self.playerService.playQueue(Array(songs.prefix(2)), startingAt: 0)
        let generation = self.playerService.beginQueueLoading()
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], songs[3]]

        await self.playerService.startRadio(song: songs[0])

        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, songs[3].videoId])
        #expect(!self.playerService.isCurrentQueueLoad(generation))
        #expect(!self.playerService.isQueueLoading)
    }

    @Test("A playlist page appended during a radio refresh does not discard the refresh")
    func playlistPageDuringRadioRefreshStillApplies() async {
        let songs = TestFixtures.makeSongs(count: 4)
        await self.playerService.playQueue(Array(songs.prefix(2)), startingAt: 0)
        let generation = self.playerService.beginQueueLoading()
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], songs[3]]
        self.mockClient.beforeRadioQueueReturn = { [playerService] _ in
            await playerService.appendOriginalTracks([songs[2]])
        }

        await self.playerService.startRadio(song: songs[0])

        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, songs[3].videoId])
        #expect(!self.playerService.isCurrentQueueLoad(generation))
        #expect(!self.playerService.isQueueLoading)
    }

    @Test("A user append during a playlist load discards the radio refresh")
    func userAppendDuringPlaylistLoadDiscardsRadioRefresh() async {
        let songs = TestFixtures.makeSongs(count: 4)
        await self.playerService.playQueue(Array(songs.prefix(2)), startingAt: 0)
        let generation = self.playerService.beginQueueLoading()
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], songs[3]]
        self.mockClient.beforeRadioQueueReturn = { [playerService] _ in
            await playerService.appendToQueue([songs[2]])
        }

        await self.playerService.startRadio(song: songs[0])

        #expect(self.playerService.queue.map(\.videoId) == songs.prefix(3).map(\.videoId))
        #expect(self.playerService.isCurrentQueueLoad(generation))
        #expect(self.playerService.isQueueLoading)
    }

    @Test("A playlist load that finishes during a radio refresh does not discard the refresh")
    func playlistLoadFinishingDuringRadioRefreshStillApplies() async {
        let songs = TestFixtures.makeSongs(count: 4)
        await self.playerService.playQueue(Array(songs.prefix(2)), startingAt: 0)
        let generation = self.playerService.beginQueueLoading()
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], songs[3]]
        self.mockClient.beforeRadioQueueReturn = { [playerService] _ in
            await playerService.appendOriginalTracks([songs[2]])
            await playerService.endQueueLoading(generation)
        }

        await self.playerService.startRadio(song: songs[0])

        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, songs[3].videoId])
        #expect(!self.playerService.isQueueLoading)
    }

    @Test("A Smart Shuffle fill that lands during a radio refresh does not discard the refresh")
    func smartShuffleFillAheadOfRadioRefresh() async {
        let songs = TestFixtures.makeSongs(count: 3)
        let suggested = TestFixtures.makeSong(id: "suggested-1")
        let recommended = TestFixtures.makeSong(id: "rec-1")
        self.playerService.smartShuffleFeatureEnabled = { true }
        self.playerService.smartShuffleConfigProvider = {
            PlayerService.SmartShuffleConfig(suggestEveryN: 1, burst: 1, suggestionsAhead: 1)
        }
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.shuffleMode = .smart
        self.playerService.updatePlaybackState(isPlaying: true, progress: 42, duration: 240)
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], suggested]

        let radioGate = AsyncGate()
        self.mockClient.getRadioQueueGate = radioGate

        let userMutationGenerationBeforeFill = self.playerService.userQueueMutationGeneration
        let refreshTask = Task { @MainActor [playerService] in
            await playerService.startRadio(song: songs[0])
        }
        for _ in 0 ..< 1000 where self.mockClient.getRadioQueueVideoIds.isEmpty {
            await Task.yield()
        }
        #expect(self.mockClient.getRadioQueueVideoIds == [songs[0].videoId])

        self.mockClient.getRadioQueueGate = nil
        await self.playerService.fillSmartShuffleWindow()
        #expect(self.playerService.queueEntries.contains {
            $0.song.videoId == suggested.videoId && $0.source == .suggested
        })
        #expect(self.playerService.userQueueMutationGeneration == userMutationGenerationBeforeFill)

        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], recommended]
        await radioGate.open()
        await refreshTask.value

        #expect(self.playerService.currentTrack?.videoId == songs[0].videoId)
        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, recommended.videoId])
    }

    @Test("An unavailable radio refresh keeps an in-flight Smart Shuffle fill")
    func unavailableRadioRefreshKeepsSmartShuffleFill() async {
        let songs = TestFixtures.makeSongs(count: 3)
        let suggested = TestFixtures.makeSong(id: "suggested-1")
        self.playerService.smartShuffleFeatureEnabled = { true }
        self.playerService.smartShuffleConfigProvider = {
            PlayerService.SmartShuffleConfig(suggestEveryN: 1, burst: 1, suggestionsAhead: 1)
        }
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.shuffleMode = .smart
        self.playerService.updatePlaybackState(isPlaying: true, progress: 42, duration: 240)

        let fillGate = AsyncGate()
        self.mockClient.getRadioQueueGate = fillGate
        let fillTask = Task { @MainActor [playerService] in
            await playerService.fillSmartShuffleWindow()
        }
        for _ in 0 ..< 1000 where self.mockClient.getRadioQueueVideoIds.isEmpty {
            await Task.yield()
        }
        #expect(self.mockClient.getRadioQueueVideoIds.count == 1)

        self.mockClient.getRadioQueueGate = nil
        self.mockClient.radioQueueSongs[songs[0].videoId] = []
        await self.playerService.startRadio(song: songs[0])

        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], suggested]
        await fillGate.open()
        await fillTask.value

        #expect(self.playerService.queueEntries.contains {
            $0.song.videoId == suggested.videoId && $0.source == .suggested
        })
    }

    @Test("A shuffled radio refresh keeps the original order of the retained songs")
    func shuffledRadioRefreshKeepsOriginalOrder() async {
        let songs = TestFixtures.makeSongs(count: 4)
        let recommended = (1 ... 3).map { TestFixtures.makeSong(id: "rec-\($0)") }
        await self.playerService.playQueue(songs, startingAt: 0)
        let entries = self.playerService.queueEntries
        self.playerService.shuffleMode = .on
        self.playerService.queueOrderBeforeShuffle = entries
        self.playerService.setQueue(entries: [entries[2], entries[1], entries[0], entries[3]])
        self.playerService.currentIndex = 2
        self.playerService.updatePlaybackState(isPlaying: true, progress: 42, duration: 240)
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0]] + recommended

        await self.playerService.startRadio(song: songs[0])

        #expect(Array(self.playerService.queueEntryIDs.prefix(3)) == [entries[2].id, entries[1].id, entries[0].id])
        #expect(Set(self.playerService.queue.dropFirst(3).map(\.videoId)) == Set(recommended.map(\.videoId)))

        self.playerService.setShuffleMode(.off)

        #expect(Array(self.playerService.queueEntryIDs.prefix(3)) == [entries[0].id, entries[1].id, entries[2].id])
        #expect(self.playerService.queue.map(\.videoId) == songs.prefix(3).map(\.videoId) + recommended.map(\.videoId))
    }

    @Test("Seeking during a Smart Shuffle radio refresh still fills suggestions")
    func seekDuringSmartShuffleRadioRefreshFills() async {
        let songs = TestFixtures.makeSongs(count: 2)
        let recommended = TestFixtures.makeSong(id: "rec-1")
        let suggested = TestFixtures.makeSong(id: "suggested-1")
        self.playerService.smartShuffleFeatureEnabled = { true }
        self.playerService.smartShuffleConfigProvider = {
            PlayerService.SmartShuffleConfig(suggestEveryN: 1, burst: 1, suggestionsAhead: 1)
        }
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.shuffleMode = .smart
        self.playerService.updatePlaybackState(isPlaying: true, progress: 42, duration: 240)
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], recommended]
        self.mockClient.radioQueueSongs[recommended.videoId] = [suggested]
        self.mockClient.beforeRadioQueueReturn = { [playerService, mockClient] videoId in
            guard videoId == songs[0].videoId else { return }
            await MainActor.run { mockClient.beforeRadioQueueReturn = nil }
            await playerService.seek(to: 60)
        }

        await self.playerService.startRadio(song: songs[0])

        #expect(self.playerService.queueEntries.contains {
            $0.song.videoId == suggested.videoId && $0.source == .suggested
        })
    }

    @Test("Start Radio on a playing artist episode leaves episode mode")
    func startRadioOnEpisodeClearsEpisode() async {
        let songs = TestFixtures.makeSongs(count: 2)
        await self.playerService.playQueue([songs[0]], startingAt: 0)
        self.playerService.currentEpisode = ArtistEpisode(videoId: songs[0].videoId, title: "Episode")
        self.playerService.updatePlaybackState(isPlaying: true, progress: 42, duration: 240)
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], songs[1]]

        await self.playerService.startRadio(song: songs[0])

        #expect(self.playerService.currentEpisode == nil)
        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, songs[1].videoId])
    }

    @Test("A mix continuation that lands during a radio refresh does not discard the refresh")
    func mixContinuationDuringRadioRefreshStillApplies() async {
        let songs = TestFixtures.makeSongs(count: 4)
        await self.playerService.playQueue(Array(songs.prefix(2)), startingAt: 0)
        self.playerService.mixContinuationToken = "mix-continuation"
        self.mockClient.mixQueueContinuationResult = RadioQueueResult(
            songs: [songs[2]],
            continuationToken: "next-mix-continuation"
        )
        self.mockClient.radioQueueSongs[songs[0].videoId] = [songs[0], songs[3]]
        let radioGate = AsyncGate()
        self.mockClient.getRadioQueueGate = radioGate

        let userMutationGenerationBeforeAppend = self.playerService.userQueueMutationGeneration
        let refreshTask = Task { @MainActor [playerService] in
            await playerService.startRadio(song: songs[0])
        }
        for _ in 0 ..< 1000 where self.mockClient.getRadioQueueVideoIds.isEmpty {
            await Task.yield()
        }
        #expect(self.mockClient.getRadioQueueVideoIds == [songs[0].videoId])

        await self.playerService.fetchMoreMixSongsIfNeeded()
        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, songs[1].videoId, songs[2].videoId])
        #expect(self.playerService.userQueueMutationGeneration == userMutationGenerationBeforeAppend)

        await radioGate.open()
        await refreshTask.value

        #expect(self.playerService.queue.map(\.videoId) == [songs[0].videoId, songs[3].videoId])
        #expect(self.playerService.mixContinuationToken == nil)
    }
}

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
