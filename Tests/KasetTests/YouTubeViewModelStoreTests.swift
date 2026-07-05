import Testing
@testable import Kaset

@Suite("YouTubeViewModelStore", .serialized, .tags(.viewModel))
@MainActor
struct YouTubeViewModelStoreTests {
    @Test("Guest refresh reloads public video feeds")
    func guestRefreshReloadsPublicVideoFeeds() async {
        let client = MockYouTubeClient()
        client.homeFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "guest-home")],
            continuation: nil
        )
        client.destinationFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "guest-explore")],
            continuation: nil
        )
        client.shorts = [MockYouTubeClient.makeVideo(videoId: "guest-short", isShort: true)]
        let sut = YouTubeViewModelStore(client: client)

        await sut.refreshGuestContent()

        #expect(client.homeFeedCallCount == 1)
        #expect(client.destinationFeedCallCount == 1)
        #expect(client.lastDestination == .gaming)
        #expect(client.shortsCallCount == 1)
        #expect(sut.home.videos.map(\.videoId) == ["guest-home"])
        #expect(sut.explore.videos.map(\.videoId) == ["guest-explore"])
        #expect(sut.shorts.shorts.map(\.videoId) == ["guest-short"])
    }
}
