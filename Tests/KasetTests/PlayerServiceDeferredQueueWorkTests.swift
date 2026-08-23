import Foundation
import Testing
@testable import Kaset

@Suite("Player service deferred queue work", .serialized, .tags(.service))
@MainActor
struct PlayerServiceDeferredQueueWorkTests {
    @Test("A transport intent does not orphan a committed deferred queue load")
    func pauseDoesNotOrphanDeferredQueueLoad() async throws {
        let client = MockYTMusicClient()
        let playerService = PlayerService()
        playerService.setYTMusicClient(client)
        let metadataStarted = AsyncGate()
        let releaseMetadata = AsyncGate()
        let song = Song(id: "initial", title: "Initial", artists: [], videoId: "initial")
        client.songResponses[song.videoId] = song
        client.beforeGetSongReturn = { _ in
            await metadataStarted.open()
            await releaseMetadata.wait()
        }

        let playTask = Task { @MainActor in
            await playerService.playQueue(
                [song],
                startingAt: 0,
                deferringSmartShuffleFill: true
            )
        }
        await metadataStarted.wait()
        await playerService.pause()
        await releaseMetadata.open()
        let loadGeneration = try #require(await playTask.value)

        #expect(playerService.isCurrentQueueLoad(loadGeneration))
        #expect(playerService.isQueueLoading)
        #expect(playerService.restoredPlaybackSessionOwnerScope != nil)

        await playerService.endQueueLoading(loadGeneration)
        #expect(!playerService.isQueueLoading)
    }

    @Test("Playlist continuation cannot append after stop")
    func continuationCannotAppendAfterStop() async {
        let context = self.makeDelayedPlaylistContext(id: "stop")
        let task = PlaylistPlaybackActions.playPlaylist(
            context.playlist,
            client: context.client,
            playerService: context.playerService
        )
        await context.continuationStarted.wait()

        await context.playerService.stop()
        await context.releaseContinuation.open()
        await task.value

        #expect(context.playerService.queue.map(\.videoId) == ["initial-stop"])
        #expect(!context.playerService.isQueueLoading)
    }

    @Test("Playlist continuation cannot repopulate a cleared queue")
    func continuationCannotAppendAfterClear() async {
        let context = self.makeDelayedPlaylistContext(id: "clear")
        let task = PlaylistPlaybackActions.playPlaylist(
            context.playlist,
            client: context.client,
            playerService: context.playerService
        )
        await context.continuationStarted.wait()

        await context.playerService.clearQueueEntirely()
        await context.releaseContinuation.open()
        await task.value

        #expect(context.playerService.queue.isEmpty)
        #expect(!context.playerService.isQueueLoading)
    }

    @Test("Playlist continuation cannot repopulate playback after privacy clearing")
    func continuationCannotAppendAfterPrivacyClear() async {
        let context = self.makeDelayedPlaylistContext(id: "privacy")
        let task = PlaylistPlaybackActions.playPlaylist(
            context.playlist,
            client: context.client,
            playerService: context.playerService
        )
        await context.continuationStarted.wait()

        context.playerService.clearPlaybackForSignOut()
        await context.releaseContinuation.open()
        await task.value

        #expect(context.playerService.queue.isEmpty)
        #expect(context.playerService.currentTrack == nil)
        #expect(!context.playerService.isQueueLoading)
    }

    @Test("Playlist continuation cannot append into an adopted restored queue")
    func continuationCannotAppendIntoRestoredQueue() async {
        let context = self.makeDelayedPlaylistContext(id: "restore")
        let task = PlaylistPlaybackActions.playPlaylist(
            context.playlist,
            client: context.client,
            playerService: context.playerService
        )
        await context.continuationStarted.wait()
        let restored = Song(
            id: "restored",
            title: "Restored",
            artists: [],
            duration: 180,
            videoId: "restored",
            feedbackTokens: .init(add: nil, remove: nil)
        )

        context.playerService.applyRestoredPlaybackSession(
            queue: [restored],
            currentIndex: 0,
            progress: 12,
            duration: 180
        )
        await context.releaseContinuation.open()
        await task.value

        #expect(context.playerService.queue == [restored])
        #expect(context.playerService.currentTrack == restored)
        #expect(!context.playerService.isQueueLoading)
    }

    private func makeDelayedPlaylistContext(id: String) -> Context {
        let client = MockYTMusicClient()
        let playerService = PlayerService()
        let continuationStarted = AsyncGate()
        let releaseContinuation = AsyncGate()
        let playlist = TestFixtures.makePlaylist(id: "VL-\(id)", title: id)
        let initial = Song(
            id: "initial-\(id)",
            title: "Initial",
            artists: [],
            videoId: "initial-\(id)"
        )
        let continuation = Song(
            id: "continuation-\(id)",
            title: "Continuation",
            artists: [],
            videoId: "continuation-\(id)"
        )
        client.playlistDetails[playlist.id] = PlaylistDetail(
            playlist: playlist,
            tracks: [initial],
            duration: nil
        )
        client.playlistContinuationTracks[playlist.id] = [[continuation]]
        client.beforePlaylistContinuationReturn = { _ in
            await continuationStarted.open()
            await releaseContinuation.wait()
        }
        return Context(
            client: client,
            playerService: playerService,
            playlist: playlist,
            continuationStarted: continuationStarted,
            releaseContinuation: releaseContinuation
        )
    }

    private struct Context {
        let client: MockYTMusicClient
        let playerService: PlayerService
        let playlist: Playlist
        let continuationStarted: AsyncGate
        let releaseContinuation: AsyncGate
    }
}
