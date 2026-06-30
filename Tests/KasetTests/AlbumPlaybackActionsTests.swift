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

    private func awaitQueueCount(_ expectedCount: Int) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))

        while self.playerService.queue.count != expectedCount {
            guard clock.now < deadline else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
