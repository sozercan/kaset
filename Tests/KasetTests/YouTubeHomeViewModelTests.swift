import Foundation
import Testing
@testable import Kaset

@Suite("YouTubeHomeViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct YouTubeHomeViewModelTests {
    let mockClient: MockYouTubeClient
    let sut: YouTubeHomeViewModel

    init() {
        self.mockClient = MockYouTubeClient()
        self.sut = YouTubeHomeViewModel(client: self.mockClient)
    }

    @Test("Initial state is idle and empty")
    func initialState() {
        #expect(self.sut.loadingState == .idle)
        #expect(self.sut.videos.isEmpty)
    }

    @Test("Load populates videos from the client")
    func loadPopulatesVideos() async {
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )

        await self.sut.load()

        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.videos.count == 3)
        #expect(self.sut.hasMoreVideos == false)
    }

    @Test("Load failure surfaces an error state")
    func loadFailure() async {
        self.mockClient.error = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.sut.load()

        if case .error = self.sut.loadingState {
            // expected
        } else {
            Issue.record("Expected error state, got \(self.sut.loadingState)")
        }
        #expect(self.sut.videos.isEmpty)
    }

    @Test("LoadMore appends new videos and skips duplicates")
    func loadMoreAppendsAndDeduplicates() async {
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 2),
            continuation: "token"
        )
        self.mockClient.homeFeedContinuation = YouTubeFeed(
            videos: [
                MockYouTubeClient.makeVideo(videoId: "video-1"), // duplicate
                MockYouTubeClient.makeVideo(videoId: "video-new"),
            ],
            continuation: nil
        )

        await self.sut.load()
        #expect(self.sut.hasMoreVideos)

        await self.sut.loadMore()

        #expect(self.sut.videos.map(\.videoId) == ["video-0", "video-1", "video-new"])
        #expect(self.sut.loadingState == .loaded)
    }

    @Test("Refresh reloads from scratch")
    func refreshReloads() async {
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 1),
            continuation: nil
        )
        await self.sut.load()
        #expect(self.mockClient.homeFeedCallCount == 1)

        await self.sut.refresh()

        #expect(self.mockClient.homeFeedCallCount == 2)
        #expect(self.sut.loadingState == .loaded)
    }
}
