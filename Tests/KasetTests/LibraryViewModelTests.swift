import XCTest
@testable import Kaset

/// Tests for LibraryViewModel using mock client.
@MainActor
final class LibraryViewModelTests: XCTestCase {
    private var mockClient: MockYTMusicClient!
    private var viewModel: LibraryViewModel!

    override func setUp() async throws {
        self.mockClient = MockYTMusicClient()
        self.viewModel = LibraryViewModel(client: self.mockClient)
    }

    override func tearDown() async throws {
        self.mockClient = nil
        self.viewModel = nil
    }

    func testInitialState() {
        XCTAssertEqual(self.viewModel.loadingState, .idle)
        XCTAssertTrue(self.viewModel.playlists.isEmpty)
        XCTAssertNil(self.viewModel.selectedPlaylistDetail)
    }

    func testLoadSuccess() async {
        // Given
        self.mockClient.libraryPlaylists = [
            TestFixtures.makePlaylist(id: "VL1", title: "Playlist 1"),
            TestFixtures.makePlaylist(id: "VL2", title: "Playlist 2"),
        ]

        // When
        await self.viewModel.load()

        // Then
        XCTAssertTrue(self.mockClient.getLibraryPlaylistsCalled)
        XCTAssertEqual(self.viewModel.loadingState, .loaded)
        XCTAssertEqual(self.viewModel.playlists.count, 2)
        XCTAssertEqual(self.viewModel.playlists[0].title, "Playlist 1")
    }

    func testLoadError() async {
        // Given
        self.mockClient.shouldThrowError = YTMusicError.authExpired

        // When
        await self.viewModel.load()

        // Then
        XCTAssertTrue(self.mockClient.getLibraryPlaylistsCalled)
        if case .error = self.viewModel.loadingState {
            // Expected
        } else {
            XCTFail("Expected error state")
        }
        XCTAssertTrue(self.viewModel.playlists.isEmpty)
    }

    func testLoadPlaylistSuccess() async {
        // Given
        let playlist = TestFixtures.makePlaylist(id: "VL-test")
        let playlistDetail = TestFixtures.makePlaylistDetail(playlist: playlist, trackCount: 5)
        self.mockClient.playlistDetails["VL-test"] = playlistDetail

        // When
        await self.viewModel.loadPlaylist(id: "VL-test")

        // Then
        XCTAssertTrue(self.mockClient.getPlaylistCalled)
        XCTAssertEqual(self.mockClient.getPlaylistIds.first, "VL-test")
        XCTAssertEqual(self.viewModel.playlistDetailLoadingState, .loaded)
        XCTAssertNotNil(self.viewModel.selectedPlaylistDetail)
        XCTAssertEqual(self.viewModel.selectedPlaylistDetail?.tracks.count, 5)
    }

    func testClearSelectedPlaylist() async {
        // Given - load a playlist
        let playlist = TestFixtures.makePlaylist(id: "VL-test")
        self.mockClient.playlistDetails["VL-test"] = TestFixtures.makePlaylistDetail(playlist: playlist)
        await self.viewModel.loadPlaylist(id: "VL-test")
        XCTAssertNotNil(self.viewModel.selectedPlaylistDetail)

        // When
        self.viewModel.clearSelectedPlaylist()

        // Then
        XCTAssertNil(self.viewModel.selectedPlaylistDetail)
        XCTAssertEqual(self.viewModel.playlistDetailLoadingState, .idle)
    }

    func testRefreshClearsAndReloads() async {
        // Given - load initial data
        self.mockClient.libraryPlaylists = [TestFixtures.makePlaylist(id: "VL1")]
        await self.viewModel.load()
        XCTAssertEqual(self.viewModel.playlists.count, 1)

        // When - refresh with different data
        self.mockClient.libraryPlaylists = [
            TestFixtures.makePlaylist(id: "VL2"),
            TestFixtures.makePlaylist(id: "VL3"),
        ]
        await self.viewModel.refresh()

        // Then
        XCTAssertEqual(self.viewModel.playlists.count, 2)
    }
}
