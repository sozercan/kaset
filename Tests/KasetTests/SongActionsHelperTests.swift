import Foundation
import Testing
@testable import Kaset

/// Tests for SongActionsHelper library mutation flows.
@Suite(.serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct SongActionsHelperTests {
    var mockClient: MockYTMusicClient
    var libraryViewModel: LibraryViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.libraryViewModel = LibraryViewModel(client: self.mockClient)
    }

    @Test("addPlaylistToLibrary keeps optimistic playlist when refresh response is stale")
    func addPlaylistToLibraryPreservesOptimisticPlaylist() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist", title: "Test Playlist")
        self.mockClient.shouldAutoUpdatePlaylistLibraryOnMutation = false

        await SongActionsHelper.addPlaylistToLibrary(
            playlist,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )

        #expect(self.mockClient.subscribeToPlaylistCalled == true)
        #expect(self.mockClient.getLibraryContentCalled == true)
        #expect(self.libraryViewModel.isInLibrary(playlistId: playlist.id) == true)
        #expect(self.libraryViewModel.playlists.first?.id == playlist.id)
    }

    @Test("removePlaylistFromLibrary keeps optimistic removal when refresh response is stale")
    func removePlaylistFromLibraryPreservesOptimisticRemoval() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist", title: "Test Playlist")
        self.mockClient.libraryPlaylists = [playlist]
        self.mockClient.shouldAutoUpdatePlaylistLibraryOnMutation = false

        await self.libraryViewModel.load()
        self.mockClient.reset()

        await SongActionsHelper.removePlaylistFromLibrary(
            playlist,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )

        #expect(self.mockClient.unsubscribeFromPlaylistCalled == true)
        #expect(self.mockClient.getLibraryContentCalled == true)
        #expect(self.libraryViewModel.isInLibrary(playlistId: playlist.id) == false)
        #expect(self.libraryViewModel.playlists.isEmpty)
    }

    @Test("subscribeToPodcast keeps optimistic show when refresh response is stale")
    func subscribeToPodcastPreservesOptimisticShow() async throws {
        let show = TestFixtures.makePodcastShow(id: "MPSPPL-test-podcast", title: "Test Podcast")
        self.mockClient.shouldAutoUpdatePodcastLibraryOnMutation = false

        try await SongActionsHelper.subscribeToPodcast(
            show,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )

        #expect(self.mockClient.getLibraryContentCalled == true)
        #expect(self.libraryViewModel.isInLibrary(podcastId: show.id) == true)
        #expect(self.libraryViewModel.podcastShows.first?.id == show.id)
    }

    @Test("unsubscribeFromPodcast keeps optimistic removal when refresh response is stale")
    func unsubscribeFromPodcastPreservesOptimisticRemoval() async throws {
        let show = TestFixtures.makePodcastShow(id: "MPSPPL-test-podcast", title: "Test Podcast")
        self.mockClient.libraryPodcastShows = [show]
        self.mockClient.shouldAutoUpdatePodcastLibraryOnMutation = false

        await self.libraryViewModel.load()
        self.mockClient.reset()

        try await SongActionsHelper.unsubscribeFromPodcast(
            show,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )

        #expect(self.mockClient.getLibraryContentCalled == true)
        #expect(self.libraryViewModel.isInLibrary(podcastId: show.id) == false)
        #expect(self.libraryViewModel.podcastShows.isEmpty)
    }
}
