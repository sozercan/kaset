import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct AlbumPlaybackActionsTests {
    var mockClient: MockYTMusicClient
    var playerService: PlayerService

    init() {
        self.mockClient = MockYTMusicClient()
        self.playerService = PlayerService()
    }

    @Test("Add album to queue last fetches and prepares album songs")
    func addAlbumToQueueLastFetchesAndPreparesAlbumSongs() async {
        let album = TestFixtures.makeAlbum(id: "MPRE-album", title: "Album Title", artistName: "Album, Album Artist")
        let track = Song(id: "track-1", title: "Track 1", artists: [], videoId: "track-1", isExplicit: true)
        let playlist = TestFixtures.makePlaylist(id: album.id, title: album.title)
        self.mockClient.playlistDetails[album.id] = PlaylistDetail(
            playlist: playlist,
            tracks: [track],
            duration: nil
        )

        AlbumPlaybackActions.addAlbumToQueueLast(
            album,
            client: self.mockClient,
            playerService: self.playerService
        )

        await self.awaitQueueCount(1)

        #expect(self.playerService.queue.first?.title == "Track 1")
        #expect(self.playerService.queue.first?.artists.map(\.name) == ["Album Artist"])
        #expect(self.playerService.queue.first?.album?.id == album.id)
        #expect(self.playerService.queue.first?.thumbnailURL == album.thumbnailURL)
        #expect(self.playerService.queue.first?.isExplicit == true)
    }

    @Test("A delayed album cannot replace a newer direct queue")
    func delayedAlbumCannotReplaceNewerQueue() async {
        let album = TestFixtures.makeAlbum(id: "MPRE-delayed", title: "Delayed", artistName: "Artist")
        let playlist = TestFixtures.makePlaylist(id: album.id, title: album.title)
        self.mockClient.playlistDetails[album.id] = PlaylistDetail(
            playlist: playlist,
            tracks: [Song(id: "stale", title: "Stale", artists: [], videoId: "stale")],
            duration: nil
        )
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.mockClient.beforeGetPlaylistReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let albumTask = AlbumPlaybackActions.playAlbum(
            album,
            client: self.mockClient,
            playerService: self.playerService
        )
        await requestStarted.wait()
        let replacement = Song(
            id: "replacement",
            title: "Replacement",
            artists: [],
            videoId: "replacement"
        )
        await self.playerService.playQueue([replacement], startingAt: 0)
        let replacementEntryIDs = self.playerService.queueEntryIDs

        await releaseRequest.open()
        await albumTask.value

        #expect(self.playerService.queue == [replacement])
        #expect(self.playerService.queueEntryIDs == replacementEntryIDs)
        #expect(self.playerService.currentTrack?.videoId == replacement.videoId)
    }

    @Test("A delayed album addition cannot target a replacement queue")
    func delayedAlbumAdditionCannotMutateReplacementQueue() async {
        let album = TestFixtures.makeAlbum(id: "MPRE-add-delayed", title: "Delayed", artistName: "Artist")
        let playlist = TestFixtures.makePlaylist(id: album.id, title: album.title)
        self.mockClient.playlistDetails[album.id] = PlaylistDetail(
            playlist: playlist,
            tracks: [Song(id: "stale", title: "Stale", artists: [], videoId: "stale")],
            duration: nil
        )
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.mockClient.beforeGetPlaylistReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }
        let original = Song(id: "original", title: "Original", artists: [], videoId: "original")
        await self.playerService.playQueue([original], startingAt: 0)

        let additionTask = AlbumPlaybackActions.addAlbumToQueueLast(
            album,
            client: self.mockClient,
            playerService: self.playerService
        )
        await requestStarted.wait()
        let replacement = Song(
            id: "replacement",
            title: "Replacement",
            artists: [],
            videoId: "replacement"
        )
        await self.playerService.playQueue([replacement], startingAt: 0)
        let replacementEntryIDs = self.playerService.queueEntryIDs

        await releaseRequest.open()
        await additionTask.value

        #expect(self.playerService.queue == [replacement])
        #expect(self.playerService.queueEntryIDs == replacementEntryIDs)
    }

    @Test("Pausing does not cancel a pending album addition")
    func pausePreservesPendingAlbumAddition() async {
        let album = TestFixtures.makeAlbum(id: "MPRE-add-pause", title: "Delayed", artistName: "Artist")
        let playlist = TestFixtures.makePlaylist(id: album.id, title: album.title)
        let albumSong = Song(id: "album-song", title: "Album Song", artists: [], videoId: "album-song")
        self.mockClient.playlistDetails[album.id] = PlaylistDetail(
            playlist: playlist,
            tracks: [albumSong],
            duration: nil
        )
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.mockClient.beforeGetPlaylistReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }
        let current = Song(id: "current", title: "Current", artists: [], videoId: "current")
        await self.playerService.playQueue([current], startingAt: 0)

        let additionTask = AlbumPlaybackActions.addAlbumToQueueLast(
            album,
            client: self.mockClient,
            playerService: self.playerService
        )
        await requestStarted.wait()
        await self.playerService.pause()
        await releaseRequest.open()
        await additionTask.value

        #expect(self.playerService.queue.map(\.videoId) == [current.videoId, albumSong.videoId])
    }

    private func awaitQueueCount(_ expectedCount: Int) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))

        while self.playerService.queue.count != expectedCount {
            guard clock.now < deadline else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
