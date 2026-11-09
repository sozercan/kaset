import Foundation
import Testing
@testable import Kaset

/// Tests that Music and YouTube Home reload stale content on demand, so
/// recommendations rotate in long-running sessions without a relaunch.
@Suite(.serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct HomeStaleRefreshTests {
    @Test("Music Home leaves recently loaded content alone")
    func musicSkipsFreshContent() async {
        let client = MockYTMusicClient()
        let viewModel = HomeViewModel(client: client)
        client.homeResponse = TestFixtures.makeHomeResponse(sectionCount: 2)
        await viewModel.load()

        await viewModel.refreshIfStale(now: Date().addingTimeInterval(60))

        #expect(client.getHomeForceRefreshes == [false])
    }

    @Test("Music Home reloads once its content is older than the stale interval")
    func musicReloadsOldContent() async {
        let client = MockYTMusicClient()
        let viewModel = HomeViewModel(client: client)
        client.homeResponse = TestFixtures.makeHomeResponse(sectionCount: 2)
        await viewModel.load()
        client.homeResponse = TestFixtures.makeHomeResponse(sectionCount: 3)

        await viewModel.refreshIfStale(now: Date().addingTimeInterval(HomeViewModel.staleContentInterval + 1))

        #expect(client.getHomeForceRefreshes == [false, true])
        #expect(viewModel.sections.count == 3)
    }

    @Test("Music Home does not start a load before it has loaded once")
    func musicIgnoresIdleHome() async {
        let client = MockYTMusicClient()
        let viewModel = HomeViewModel(client: client)

        await viewModel.refreshIfStale(now: Date().addingTimeInterval(HomeViewModel.staleContentInterval + 1))

        #expect(client.getHomeCallCount == 0)
        #expect(viewModel.loadingState == .idle)
    }

    @Test("YouTube Home only reloads a feed older than the stale interval")
    func youTubeRespectsInterval() async {
        let client = MockYouTubeClient()
        let viewModel = YouTubeHomeViewModel(client: client)
        client.homeFeed = YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil)
        await viewModel.load()

        await viewModel.refreshIfStale(now: Date().addingTimeInterval(60))
        #expect(client.homeBundleForceRefreshes == [false])

        await viewModel.refreshIfStale(now: Date().addingTimeInterval(YouTubeHomeViewModel.staleContentInterval + 1))
        #expect(client.homeBundleForceRefreshes == [false, true])
        #expect(viewModel.loadingState == .loaded)
    }

    @Test("Music Home keeps its content when a stale refresh fails")
    func musicKeepsContentWhenStaleRefreshFails() async {
        let client = MockYTMusicClient()
        let viewModel = HomeViewModel(client: client)
        client.homeResponse = TestFixtures.makeHomeResponse(sectionCount: 2)
        await viewModel.load()
        let loadedAt = viewModel.lastLoadedAt
        client.shouldThrowError = YTMusicError.networkError(underlying: URLError(.timedOut))

        await viewModel.refreshIfStale(now: Date().addingTimeInterval(HomeViewModel.staleContentInterval + 1))

        #expect(client.getHomeForceRefreshes == [false, true])
        #expect(viewModel.loadingState == .loaded)
        #expect(viewModel.sections.count == 2)
        // The old timestamp stays, so the next trigger retries.
        #expect(viewModel.lastLoadedAt == loadedAt)
    }

    @Test("Music Home still shows the error when a manual refresh fails")
    func musicManualRefreshFailureShowsError() async {
        let client = MockYTMusicClient()
        let viewModel = HomeViewModel(client: client)
        client.homeResponse = TestFixtures.makeHomeResponse(sectionCount: 2)
        await viewModel.load()
        client.shouldThrowError = YTMusicError.networkError(underlying: URLError(.timedOut))

        await viewModel.refresh()

        guard case .error = viewModel.loadingState else {
            Issue.record("Expected .error, got \(viewModel.loadingState)")
            return
        }
    }

    @Test("YouTube Home keeps its feed when a stale refresh fails")
    func youTubeKeepsFeedWhenStaleRefreshFails() async {
        let client = MockYouTubeClient()
        let viewModel = YouTubeHomeViewModel(client: client)
        client.homeFeed = YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil)
        await viewModel.load()
        let videoIDs = viewModel.videos.map(\.videoId)
        client.error = URLError(.timedOut)

        await viewModel.refreshIfStale(now: Date().addingTimeInterval(YouTubeHomeViewModel.staleContentInterval + 1))

        #expect(viewModel.loadingState == .loaded)
        #expect(viewModel.videos.map(\.videoId) == videoIDs)
    }

    @Test("A YouTube page that finishes after a refresh leaves the new feed alone")
    func youTubeRefreshDuringLoadMoreIgnoresOldPage() async {
        let client = MockYouTubeClient()
        let viewModel = YouTubeHomeViewModel(client: client)
        client.homeFeed = YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil)
        client.homeFeedContinuation = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "old-page")],
            continuation: nil
        )
        await viewModel.load()
        #expect(viewModel.hasMoreVideos)

        // Hold the page request open so the model sits in `.loadingMore`.
        let gate = AsyncGate()
        client.beforeContinuationReturn = { await gate.wait() }
        let paging = Task { await viewModel.loadMore() }
        for _ in 0 ..< 200 where viewModel.loadingState != .loadingMore {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.loadingState == .loadingMore)

        let newVideos = [
            MockYouTubeClient.makeVideo(videoId: "new-1"),
            MockYouTubeClient.makeVideo(videoId: "new-2"),
            MockYouTubeClient.makeVideo(videoId: "new-3"),
        ]
        client.homeFeed = YouTubeFeed(videos: newVideos, continuation: nil)
        await viewModel.refresh()
        #expect(viewModel.loadingState == .loaded)
        #expect(viewModel.hasMoreVideos)

        await gate.open()
        await paging.value

        #expect(viewModel.videos.map(\.videoId) == ["new-1", "new-2", "new-3"])
        #expect(viewModel.hasMoreVideos)
        #expect(viewModel.loadingState == .loaded)
    }
}
