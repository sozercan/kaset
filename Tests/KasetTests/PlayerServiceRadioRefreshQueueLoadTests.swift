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
