import Foundation
import Testing
@testable import Kaset

/// Tests for LikedMusicViewModel using mock client.
@Suite("LikedMusicViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct LikedMusicViewModelTests {
    var mockClient: MockYTMusicClient
    var viewModel: LikedMusicViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.viewModel = LikedMusicViewModel(client: self.mockClient)
    }

    @Test("Initial state is idle with empty songs")
    func initialState() {
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.songs.isEmpty)
        #expect(self.viewModel.hasMore == false)
    }

    @Test("Load success sets songs")
    func loadSuccess() async {
        self.mockClient.likedSongs = TestFixtures.makeSongs(count: 5)

        await self.viewModel.load()

        #expect(self.mockClient.getLikedSongsCalled == true)
        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.songs.count == 5)
    }

    @Test("Load success marks all songs as liked")
    func loadSuccessMarksSongsAsLiked() async {
        self.mockClient.likedSongs = TestFixtures.makeSongs(count: 3)

        await self.viewModel.load()

        for song in self.viewModel.songs {
            #expect(song.likeStatus == .like)
        }
    }

    @Test("Load error sets error state")
    func loadError() async {
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.viewModel.load()

        #expect(self.mockClient.getLikedSongsCalled == true)
        if case let .error(error) = viewModel.loadingState {
            #expect(!error.message.isEmpty)
            #expect(error.isRetryable)
        } else {
            Issue.record("Expected error state")
        }
        #expect(self.viewModel.songs.isEmpty)
    }

    @Test("Load does not duplicate when already loading")
    func loadDoesNotDuplicateWhenAlreadyLoading() async {
        self.mockClient.likedSongs = TestFixtures.makeSongs(count: 2)

        await self.viewModel.load()
        await self.viewModel.load()

        // After load completes, subsequent load should work again
        #expect(self.viewModel.loadingState == .loaded)
    }

    @Test("Load more appends songs")
    func loadMoreAppendsSongs() async {
        self.mockClient.likedSongs = TestFixtures.makeSongs(count: 3)
        self.mockClient.likedSongsContinuationSongs = [
            [
                TestFixtures.makeSong(id: "more-1"),
                TestFixtures.makeSong(id: "more-2"),
            ],
        ]

        await self.viewModel.load()
        #expect(self.viewModel.songs.count == 3)
        #expect(self.viewModel.hasMore == true)

        await self.viewModel.loadMore()

        #expect(self.mockClient.getLikedSongsContinuationCalled == true)
        #expect(self.viewModel.songs.count == 5)
    }

    @Test("Load more deduplicates songs")
    func loadMoreDeduplicates() async {
        self.mockClient.likedSongs = TestFixtures.makeSongs(count: 2)
        self.mockClient.likedSongsContinuationSongs = [
            [
                TestFixtures.makeSong(id: "video-0"), // Duplicate
                TestFixtures.makeSong(id: "new-song"),
            ],
        ]

        await self.viewModel.load()
        await self.viewModel.loadMore()

        #expect(self.viewModel.songs.count == 3) // 2 original + 1 new (deduped)
        #expect(self.viewModel.songs.count(where: { $0.videoId == "video-0" }) == 1)
    }

    @Test("Load more stops when all duplicates")
    func loadMoreStopsOnAllDuplicates() async {
        self.mockClient.likedSongs = TestFixtures.makeSongs(count: 2)
        self.mockClient.likedSongsContinuationSongs = [
            [
                TestFixtures.makeSong(id: "video-0"), // Duplicate
                TestFixtures.makeSong(id: "video-1"), // Duplicate
            ],
        ]

        await self.viewModel.load()
        await self.viewModel.loadMore()

        #expect(self.viewModel.songs.count == 2)
        #expect(self.viewModel.hasMore == false)
    }

    @Test("Load more does nothing when not loaded")
    func loadMoreDoesNothingWhenNotLoaded() async {
        #expect(self.viewModel.loadingState == .idle)

        await self.viewModel.loadMore()

        #expect(self.mockClient.getLikedSongsContinuationCalled == false)
    }

    @Test("Load more does nothing when no more songs")
    func loadMoreDoesNothingWhenNoMore() async {
        self.mockClient.likedSongs = TestFixtures.makeSongs(count: 2)
        // No continuation set

        await self.viewModel.load()
        #expect(self.viewModel.hasMore == false)

        await self.viewModel.loadMore()

        #expect(self.mockClient.getLikedSongsContinuationCalled == false)
    }

    @Test("Refresh clears songs and reloads")
    func refreshClearsSongsAndReloads() async {
        self.mockClient.likedSongs = TestFixtures.makeSongs(count: 3)
        await self.viewModel.load()
        #expect(self.viewModel.songs.count == 3)

        self.mockClient.likedSongs = TestFixtures.makeSongs(count: 5)
        await self.viewModel.refresh()

        #expect(self.viewModel.songs.count == 5)
    }
}
