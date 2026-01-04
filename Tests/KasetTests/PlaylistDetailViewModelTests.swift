import Foundation
import Testing
@testable import Kaset

/// Tests for PlaylistDetailViewModel using mock client.
@Suite("PlaylistDetailViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct PlaylistDetailViewModelTests {
    var mockClient: MockYTMusicClient
    var viewModel: PlaylistDetailViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist", title: "Test Playlist")
        self.viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)
    }

    // MARK: - Initial State Tests

    @Test("Initial state is idle with no playlist detail")
    func initialState() {
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.playlistDetail == nil)
        #expect(self.viewModel.hasMore == false)
    }

    // MARK: - Load Tests

    @Test("Load success sets playlist detail")
    func loadSuccess() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 10
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail

        await self.viewModel.load()

        #expect(self.mockClient.getPlaylistCalled == true)
        #expect(self.mockClient.getPlaylistIds.first == "VL-test-playlist")
        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.playlistDetail != nil)
        #expect(self.viewModel.playlistDetail?.tracks.count == 10)
    }

    @Test("Load error sets error state")
    func loadError() async {
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.viewModel.load()

        #expect(self.mockClient.getPlaylistCalled == true)
        if case let .error(error) = viewModel.loadingState {
            #expect(!error.message.isEmpty)
            #expect(error.isRetryable)
        } else {
            Issue.record("Expected error state")
        }
        #expect(self.viewModel.playlistDetail == nil)
    }

    @Test("Load does not duplicate when already loading")
    func loadDoesNotDuplicateWhenAlreadyLoading() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 5
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail

        await self.viewModel.load()
        await self.viewModel.load()

        #expect(self.viewModel.loadingState == .loaded)
    }

    // MARK: - Load More Tests

    @Test("Load more appends tracks")
    func loadMoreAppendsTracks() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 5
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [
                TestFixtures.makeSong(id: "cont-1"),
                TestFixtures.makeSong(id: "cont-2"),
            ],
        ]

        await self.viewModel.load()
        #expect(self.viewModel.playlistDetail?.tracks.count == 5)
        #expect(self.viewModel.hasMore == true)

        await self.viewModel.loadMore()

        #expect(self.mockClient.getPlaylistContinuationCalled == true)
        #expect(self.viewModel.playlistDetail?.tracks.count == 7)
    }

    @Test("Load more deduplicates tracks")
    func loadMoreDeduplicatesTracks() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 3
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [
                TestFixtures.makeSong(id: "video-0"), // Duplicate
                TestFixtures.makeSong(id: "new-track"),
            ],
        ]

        await self.viewModel.load()
        await self.viewModel.loadMore()

        #expect(self.viewModel.playlistDetail?.tracks.count == 4) // 3 original + 1 new
    }

    @Test("Load more stops on all duplicates")
    func loadMoreStopsOnAllDuplicates() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 2
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [
                TestFixtures.makeSong(id: "video-0"),
                TestFixtures.makeSong(id: "video-1"),
            ],
        ]

        await self.viewModel.load()
        await self.viewModel.loadMore()

        #expect(self.viewModel.playlistDetail?.tracks.count == 2)
        #expect(self.viewModel.hasMore == false)
    }

    @Test("Load more does nothing when not loaded")
    func loadMoreDoesNothingWhenNotLoaded() async {
        #expect(self.viewModel.loadingState == .idle)

        await self.viewModel.loadMore()

        #expect(self.mockClient.getPlaylistContinuationCalled == false)
    }

    @Test("Load more does nothing when no more tracks")
    func loadMoreDoesNothingWhenNoMore() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 3
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail
        // No continuation tracks set

        await self.viewModel.load()
        #expect(self.viewModel.hasMore == false)

        await self.viewModel.loadMore()

        #expect(self.mockClient.getPlaylistContinuationCalled == false)
    }

    // MARK: - Refresh Tests

    @Test("Refresh clears detail and reloads")
    func refreshClearsDetailAndReloads() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 5
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail

        await self.viewModel.load()
        #expect(self.viewModel.playlistDetail?.tracks.count == 5)

        // Update mock to return different track count
        let newPlaylistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 8
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = newPlaylistDetail

        await self.viewModel.refresh()

        #expect(self.viewModel.playlistDetail?.tracks.count == 8)
    }

    // MARK: - Fallback Tests

    @Test("Load uses original playlist info for unknown title")
    func loadUsesOriginalPlaylistInfoForUnknownTitle() async {
        // Create a playlist detail with "Unknown Playlist" title
        let unknownPlaylist = Playlist(
            id: "VL-test-playlist",
            title: "Unknown Playlist",
            description: nil,
            thumbnailURL: nil,
            trackCount: 3,
            author: nil
        )
        let playlistDetail = PlaylistDetail(
            playlist: unknownPlaylist,
            tracks: TestFixtures.makeSongs(count: 3),
            duration: "10 min"
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail

        await self.viewModel.load()

        // Should use original playlist title "Test Playlist" instead of "Unknown Playlist"
        #expect(self.viewModel.playlistDetail?.title == "Test Playlist")
    }
}
