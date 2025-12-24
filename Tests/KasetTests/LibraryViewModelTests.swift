import Foundation
import Testing
@testable import Kaset

/// Tests for LibraryViewModel using mock client.
@Suite(.serialized)
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
        #expect(viewModel.loadingState == .idle)
        #expect(viewModel.playlists.isEmpty)
        #expect(viewModel.selectedPlaylistDetail == nil)
    }

    @Test("Load success sets playlists")
    func loadSuccess() async {
        mockClient.libraryPlaylists = [
            TestFixtures.makePlaylist(id: "VL1", title: "Playlist 1"),
            TestFixtures.makePlaylist(id: "VL2", title: "Playlist 2"),
        ]

        await viewModel.load()

        #expect(mockClient.getLibraryPlaylistsCalled == true)
        #expect(viewModel.loadingState == .loaded)
        #expect(viewModel.playlists.count == 2)
        #expect(viewModel.playlists[0].title == "Playlist 1")
    }

    @Test("Load error sets error state")
    func loadError() async {
        mockClient.shouldThrowError = YTMusicError.authExpired

        await viewModel.load()

        #expect(mockClient.getLibraryPlaylistsCalled == true)
        if case .error = viewModel.loadingState {
            // Expected
        } else {
            Issue.record("Expected error state")
        }
        #expect(viewModel.playlists.isEmpty)
    }

    @Test("Load playlist success")
    func loadPlaylistSuccess() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test")
        let playlistDetail = TestFixtures.makePlaylistDetail(playlist: playlist, trackCount: 5)
        mockClient.playlistDetails["VL-test"] = playlistDetail

        await viewModel.loadPlaylist(id: "VL-test")

        #expect(mockClient.getPlaylistCalled == true)
        #expect(mockClient.getPlaylistIds.first == "VL-test")
        #expect(viewModel.playlistDetailLoadingState == .loaded)
        #expect(viewModel.selectedPlaylistDetail != nil)
        #expect(viewModel.selectedPlaylistDetail?.tracks.count == 5)
    }

    @Test("Clear selected playlist")
    func clearSelectedPlaylist() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test")
        mockClient.playlistDetails["VL-test"] = TestFixtures.makePlaylistDetail(playlist: playlist)
        await viewModel.loadPlaylist(id: "VL-test")
        #expect(viewModel.selectedPlaylistDetail != nil)

        viewModel.clearSelectedPlaylist()

        #expect(viewModel.selectedPlaylistDetail == nil)
        #expect(viewModel.playlistDetailLoadingState == .idle)
    }

    @Test("Refresh clears and reloads")
    func refreshClearsAndReloads() async {
        mockClient.libraryPlaylists = [TestFixtures.makePlaylist(id: "VL1")]
        await viewModel.load()
        #expect(viewModel.playlists.count == 1)

        mockClient.libraryPlaylists = [
            TestFixtures.makePlaylist(id: "VL2"),
            TestFixtures.makePlaylist(id: "VL3"),
        ]
        await viewModel.refresh()

        #expect(viewModel.playlists.count == 2)
    }
}
