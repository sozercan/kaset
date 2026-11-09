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
}
