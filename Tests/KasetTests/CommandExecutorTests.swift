import Foundation
import Testing
@testable import Kaset

@available(macOS 26.0, *)

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct CommandExecutorTests {
    private func makeSong(title: String, artist: String, videoId: String) -> Song {
        Song(
            id: videoId,
            title: title,
            artists: [Artist(id: "artist-\(videoId)", name: artist)],
            videoId: videoId
        )
    }

    @Test("Local queue description calls out the end of a multi-item queue")
    func localQueueDescriptionAtEndOfMultiItemQueue() {
        let playerService = MockPlayerService()
        playerService.queue = [
            self.makeSong(title: "Dreams", artist: "Fleetwood Mac", videoId: "song-1"),
            self.makeSong(title: "Pink + White", artist: "Frank Ocean", videoId: "song-2"),
            self.makeSong(title: "Night Drive", artist: "Chromatics", videoId: "song-3"),
        ]
        playerService.currentIndex = 2
        playerService.state = .playing

        let executor = CommandExecutor(
            client: MockYTMusicClient(),
            playerService: playerService
        )
        let outcome = executor.describeQueueLocally()

        #expect(
            outcome.resultMessage ==
                "Now playing \"Night Drive\" by Chromatics. That's the end of your queue."
        )
        #expect(outcome.errorMessage == nil)
        #expect(outcome.shouldDismiss == false)
        #expect(outcome.searchQueryToOpen == nil)
    }

    @Test("A cancelled command cannot claim or exercise playback ownership")
    func cancelledCommandCannotClaimPlayback() async {
        let playerService = MockPlayerService()
        let executor = CommandExecutor(client: MockYTMusicClient(), playerService: playerService)
        let reservation = playerService.reserveMusicPlaybackIntent()
        let gate = AsyncGate()
        let task = Task { @MainActor in
            await gate.wait()
            return await executor.execute(.skip, reservation: reservation)
        }
        task.cancel()
        await gate.open()

        let outcome = await task.value

        #expect(outcome == .ignored)
        #expect(playerService.nextCallCount == 0)
        #expect(playerService.claimMusicPlaybackIntent(reservation) != nil)
    }

    @Test("A delayed command search cannot resurrect playback after stop")
    func delayedPlaySearchCannotResurrectAfterStop() async {
        let playerService = PlayerService()
        let client = MockYTMusicClient()
        let searchStarted = AsyncGate()
        let releaseSearch = AsyncGate()
        client.songsSearchResponse = SearchResponse(
            songs: [self.makeSong(title: "Stale", artist: "Artist", videoId: "stale")],
            albums: [],
            artists: [],
            playlists: []
        )
        client.beforeSearchReturn = { _, endpoint in
            guard endpoint == .songs else { return }
            await searchStarted.open()
            await releaseSearch.wait()
        }
        let executor = CommandExecutor(client: client, playerService: playerService)
        let reservation = playerService.reserveMusicPlaybackIntent()

        let commandTask = Task { @MainActor in
            await executor.execute(
                .playSearch(query: "stale", description: ""),
                reservation: reservation
            )
        }
        await searchStarted.wait()
        await playerService.stop()
        await releaseSearch.open()
        let outcome = await commandTask.value

        #expect(outcome == .ignored)
        #expect(playerService.state == .idle)
        #expect(playerService.queue.isEmpty)
        #expect(playerService.currentTrack == nil)
    }

    @Test("A parsed queue command cannot acquire ownership after queue replacement")
    func parsedQueueCommandCannotAdoptReplacementQueue() async {
        let playerService = PlayerService()
        let client = MockYTMusicClient()
        let executor = CommandExecutor(client: client, playerService: playerService)
        let initial = self.makeSong(title: "Initial", artist: "Artist", videoId: "initial")
        await playerService.playQueue([initial], startingAt: 0)
        let submissionReservation = playerService.reserveMusicPlaybackIntent()
        let replacement = self.makeSong(
            title: "Replacement",
            artist: "Artist",
            videoId: "replacement"
        )
        await playerService.playQueue([replacement], startingAt: 0)
        let replacementEntryIDs = playerService.queueEntryIDs
        client.songsSearchResponse = SearchResponse(
            songs: [self.makeSong(title: "Stale", artist: "Artist", videoId: "stale")],
            albums: [],
            artists: [],
            playlists: []
        )

        let outcome = await executor.execute(
            .queueSearch(query: "stale", description: ""),
            reservation: submissionReservation
        )

        #expect(outcome == .ignored)
        #expect(playerService.queue == [replacement])
        #expect(playerService.queueEntryIDs == replacementEntryIDs)
        #expect(client.searchQueries.isEmpty)
    }

    @Test("A delayed queue command cannot append into a replacement queue")
    func delayedQueueSearchCannotAppendToReplacement() async {
        let playerService = PlayerService()
        let client = MockYTMusicClient()
        let searchStarted = AsyncGate()
        let releaseSearch = AsyncGate()
        client.songsSearchResponse = SearchResponse(
            songs: [self.makeSong(title: "Stale", artist: "Artist", videoId: "stale")],
            albums: [],
            artists: [],
            playlists: []
        )
        client.beforeSearchReturn = { _, endpoint in
            guard endpoint == .songs else { return }
            await searchStarted.open()
            await releaseSearch.wait()
        }
        let executor = CommandExecutor(client: client, playerService: playerService)
        let reservation = playerService.reserveMusicPlaybackIntent()

        let commandTask = Task { @MainActor in
            await executor.execute(
                .queueSearch(query: "stale", description: ""),
                reservation: reservation
            )
        }
        await searchStarted.wait()
        let replacement = self.makeSong(
            title: "Replacement",
            artist: "Artist",
            videoId: "replacement"
        )
        await playerService.playQueue([replacement], startingAt: 0)
        let replacementEntryIDs = playerService.queueEntryIDs
        await releaseSearch.open()
        let outcome = await commandTask.value

        #expect(outcome == .ignored)
        #expect(playerService.queue == [replacement])
        #expect(playerService.queueEntryIDs == replacementEntryIDs)
    }
}
