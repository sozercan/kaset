import Foundation
import Testing
@testable import Kaset

/// Tests for LibraryViewModel using mock client.
@Suite("LibraryViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct LibraryViewModelTests {
    var mockClient: MockYTMusicClient
    var viewModel: LibraryViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.viewModel = LibraryViewModel(client: self.mockClient)
    }

    @Test("Initial state is idle with empty playlists")
    func initialState() {
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.playlists.isEmpty)
        #expect(self.viewModel.selectedPlaylistDetail == nil)
    }

    @Test("Load success sets playlists")
    func loadSuccess() async {
        self.mockClient.libraryPlaylists = [
            TestFixtures.makePlaylist(id: "VL1", title: "Playlist 1"),
            TestFixtures.makePlaylist(id: "VL2", title: "Playlist 2"),
        ]

        await self.viewModel.load()

        #expect(self.mockClient.getLibraryPlaylistsCalled == true)
        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.playlists.count == 2)
        #expect(self.viewModel.playlists[0].title == "Playlist 1")
    }

    @Test("Load error sets error state")
    func loadError() async {
        self.mockClient.shouldThrowError = YTMusicError.authExpired

        await self.viewModel.load()

        #expect(self.mockClient.getLibraryPlaylistsCalled == true)
        if case .error = self.viewModel.loadingState {
            // Expected
        } else {
            Issue.record("Expected error state")
        }
        #expect(self.viewModel.playlists.isEmpty)
    }

    @Test("Load playlist success")
    func loadPlaylistSuccess() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test")
        let playlistDetail = TestFixtures.makePlaylistDetail(playlist: playlist, trackCount: 5)
        self.mockClient.playlistDetails["VL-test"] = playlistDetail

        await self.viewModel.loadPlaylist(id: "VL-test")

        #expect(self.mockClient.getPlaylistCalled == true)
        #expect(self.mockClient.getPlaylistIds.first == "VL-test")
        #expect(self.viewModel.playlistDetailLoadingState == .loaded)
        #expect(self.viewModel.selectedPlaylistDetail != nil)
        #expect(self.viewModel.selectedPlaylistDetail?.tracks.count == 5)
    }

    @Test("Clear selected playlist")
    func clearSelectedPlaylist() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test")
        self.mockClient.playlistDetails["VL-test"] = TestFixtures.makePlaylistDetail(playlist: playlist)
        await self.viewModel.loadPlaylist(id: "VL-test")
        #expect(self.viewModel.selectedPlaylistDetail != nil)

        self.viewModel.clearSelectedPlaylist()

        #expect(self.viewModel.selectedPlaylistDetail == nil)
        #expect(self.viewModel.playlistDetailLoadingState == .idle)
    }

    @Test("Refresh clears and reloads")
    func refreshClearsAndReloads() async {
        self.mockClient.libraryPlaylists = [TestFixtures.makePlaylist(id: "VL1")]
        await self.viewModel.load()
        #expect(self.viewModel.playlists.count == 1)

        self.mockClient.libraryPlaylists = [
            TestFixtures.makePlaylist(id: "VL2"),
            TestFixtures.makePlaylist(id: "VL3"),
        ]
        await self.viewModel.refresh()

        #expect(self.viewModel.playlists.count == 2)
    }

    // MARK: - Podcast Library Tests

    @Test("addToLibrary inserts podcast at beginning and updates ID set")
    func addToLibraryInsertsPodcast() {
        let podcast = TestFixtures.makePodcastShow(id: "MPSPPLXz2p9test123", title: "Test Podcast")

        self.viewModel.addToLibrary(podcast: podcast)

        #expect(self.viewModel.libraryPodcastIds.contains("MPSPPLXz2p9test123"))
        #expect(self.viewModel.podcastShows.first?.id == "MPSPPLXz2p9test123")
        #expect(self.viewModel.podcastShows.first?.title == "Test Podcast")
    }

    @Test("addToLibrary does not duplicate existing podcast")
    func addToLibraryNoDuplicate() {
        let podcast = TestFixtures.makePodcastShow(id: "MPSPPLXz2p9test123")

        self.viewModel.addToLibrary(podcast: podcast)
        self.viewModel.addToLibrary(podcast: podcast)

        #expect(self.viewModel.podcastShows.count(where: { $0.id == "MPSPPLXz2p9test123" }) == 1)
        #expect(self.viewModel.libraryPodcastIds.count == 1)
    }

    @Test("addToLibrary inserts new podcast at position 0")
    func addToLibraryInsertsAtBeginning() {
        let podcast1 = TestFixtures.makePodcastShow(id: "MPSPPLA", title: "Podcast A")
        let podcast2 = TestFixtures.makePodcastShow(id: "MPSPPLB", title: "Podcast B")

        self.viewModel.addToLibrary(podcast: podcast1)
        self.viewModel.addToLibrary(podcast: podcast2)

        // Podcast B should be first (inserted at position 0)
        #expect(self.viewModel.podcastShows.first?.id == "MPSPPLB")
        #expect(self.viewModel.podcastShows[1].id == "MPSPPLA")
    }

    @Test("removeFromLibrary removes podcast from both set and array")
    func removeFromLibraryRemovesPodcast() {
        let podcast = TestFixtures.makePodcastShow(id: "MPSPPLXz2p9test123")
        self.viewModel.addToLibrary(podcast: podcast)
        #expect(self.viewModel.podcastShows.count == 1)
        #expect(self.viewModel.libraryPodcastIds.count == 1)

        self.viewModel.removeFromLibrary(podcastId: "MPSPPLXz2p9test123")

        #expect(self.viewModel.podcastShows.isEmpty)
        #expect(self.viewModel.libraryPodcastIds.isEmpty)
    }

    @Test("removeFromLibrary handles non-existent podcast gracefully")
    func removeFromLibraryNonExistent() {
        // Should not crash when removing non-existent podcast
        self.viewModel.removeFromLibrary(podcastId: "nonexistent")

        #expect(self.viewModel.podcastShows.isEmpty)
        #expect(self.viewModel.libraryPodcastIds.isEmpty)
    }

    @Test("isInLibrary returns true for added podcast")
    func isInLibraryForAddedPodcast() {
        let podcast = TestFixtures.makePodcastShow(id: "MPSPPLXz2p9test123")
        self.viewModel.addToLibrary(podcast: podcast)

        #expect(self.viewModel.isInLibrary(podcastId: "MPSPPLXz2p9test123") == true)
    }

    @Test("isInLibrary returns false for non-added podcast")
    func isInLibraryForNonAddedPodcast() {
        #expect(self.viewModel.isInLibrary(podcastId: "MPSPPLXz2p9test123") == false)
    }
}
