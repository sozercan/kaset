import Foundation
import Testing
@testable import Kaset

@Suite("YouTubeSearchViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct YouTubeSearchViewModelTests {
    let mockClient: MockYouTubeClient
    let sut: YouTubeSearchViewModel

    init() {
        self.mockClient = MockYouTubeClient()
        self.sut = YouTubeSearchViewModel(client: self.mockClient)
    }

    @Test("Search sends the query and selected filter to the client")
    func searchSendsQueryAndFilter() async {
        self.mockClient.searchResponse = YouTubeSearchResponse(
            videos: MockYouTubeClient.makeVideos(count: 2),
            channels: [],
            playlists: [],
            continuation: nil
        )
        self.sut.query = "swift"
        self.sut.selectedFilter = .videos

        await self.sut.search()

        #expect(self.mockClient.lastSearchQuery == "swift")
        #expect(self.mockClient.lastSearchFilter == .videos)
        #expect(self.sut.results.videos.count == 2)
        #expect(self.sut.loadingState == .loaded)
    }

    @Test("Empty query does not hit the client")
    func emptyQuerySkipsSearch() async {
        self.sut.query = "   "

        await self.sut.search()

        #expect(self.mockClient.searchCallCount == 0)
        #expect(self.sut.loadingState == .idle)
    }

    @Test("Clearing the query resets results")
    func clearingQueryResets() async {
        self.mockClient.searchResponse = YouTubeSearchResponse(
            videos: MockYouTubeClient.makeVideos(count: 1),
            channels: [],
            playlists: [],
            continuation: nil
        )
        self.sut.query = "swift"
        await self.sut.search()
        #expect(!self.sut.results.isEmpty)

        self.sut.query = ""

        #expect(self.sut.results.isEmpty)
        #expect(self.sut.loadingState == .idle)
    }

    @Test("Search failure surfaces an error state")
    func searchFailure() async {
        self.mockClient.error = YTMusicError.authExpired
        self.sut.query = "swift"

        await self.sut.search()

        if case .error = self.sut.loadingState {
            // expected
        } else {
            Issue.record("Expected error state, got \(self.sut.loadingState)")
        }
    }

    @Test("LoadMore appends continuation results without duplicates")
    func loadMoreAppends() async {
        self.mockClient.searchResponse = YouTubeSearchResponse(
            videos: MockYouTubeClient.makeVideos(count: 2),
            channels: [],
            playlists: [],
            continuation: "token"
        )
        self.mockClient.searchContinuation = YouTubeSearchResponse(
            videos: [
                MockYouTubeClient.makeVideo(videoId: "video-0"), // duplicate
                MockYouTubeClient.makeVideo(videoId: "video-extra"),
            ],
            channels: [],
            playlists: [],
            continuation: nil
        )
        self.sut.query = "swift"
        await self.sut.search()

        await self.sut.loadMore()

        #expect(self.sut.results.videos.map(\.videoId) == ["video-0", "video-1", "video-extra"])
        #expect(self.sut.results.continuation == nil)
    }
}
