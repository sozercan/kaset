import Foundation
import Testing
@testable import Kaset

// MARK: - YouTubeSingleFlightViewModelTests

@Suite("YouTube non-Home view model single-flight", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct YouTubeSingleFlightViewModelTests {
    @Test("History concurrent loads coalesce and loaded load is a no-op")
    func historyLoadCoalescesAndNoOpsWhenLoaded() async {
        let client = SingleFlightYouTubeClient()
        client.historyFeed = YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil)
        let gate = AsyncGate()
        client.gate = gate
        let sut = YouTubeHistoryViewModel(client: client)

        let first = Task { await sut.load() }
        await self.waitUntil(client.historyCallCount == 1, "history request started")
        let second = Task { await sut.load() }
        await Task.yield()
        first.cancel()
        await Task.yield()

        #expect(client.historyCallCount == 1)
        await gate.open()
        await first.value
        await second.value

        #expect(sut.loadingState == .loaded)
        #expect(sut.videos.count == 2)
        await sut.load()
        #expect(client.historyCallCount == 1)

        client.gate = nil
        await sut.refresh()
        #expect(client.historyCallCount == 2)
    }

    @Test("Subscriptions concurrent loads coalesce feed and channel rail requests")
    func subscriptionsLoadCoalescesFeedAndChannels() async {
        let client = SingleFlightYouTubeClient()
        client.subscriptionsFeed = YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 3), continuation: nil)
        client.subscribedChannels = [YouTubeChannel(channelId: "UC1", name: "One")]
        let gate = AsyncGate()
        client.gate = gate
        let sut = YouTubeSubscriptionsViewModel(client: client)

        let first = Task { await sut.load() }
        await self.waitUntil(
            client.subscriptionsFeedCallCount == 1 && client.subscribedChannelsCallCount == 1,
            "subscriptions requests started"
        )
        let second = Task { await sut.load() }
        await Task.yield()
        first.cancel()
        await Task.yield()

        #expect(client.subscriptionsFeedCallCount == 1)
        #expect(client.subscribedChannelsCallCount == 1)
        await gate.open()
        await first.value
        await second.value

        #expect(sut.loadingState == .loaded)
        #expect(sut.videos.count == 3)
        #expect(sut.channels.count == 1)
        await sut.load()
        #expect(client.subscriptionsFeedCallCount == 1)
        #expect(client.subscribedChannelsCallCount == 1)

        client.gate = nil
        await sut.refresh()
        #expect(client.subscriptionsFeedCallCount == 2)
        #expect(client.subscribedChannelsCallCount == 2)
    }

    @Test("Shorts concurrent loads coalesce and refresh forces a reload")
    func shortsLoadCoalescesAndRefreshes() async {
        let client = SingleFlightYouTubeClient()
        client.shorts = MockYouTubeClient.makeVideos(count: 2)
        let gate = AsyncGate()
        client.gate = gate
        let sut = YouTubeShortsViewModel(client: client)

        let first = Task { await sut.load() }
        await self.waitUntil(client.shortsCallCount == 1, "Shorts request started")
        let second = Task { await sut.load() }
        await Task.yield()
        first.cancel()
        await Task.yield()

        #expect(client.shortsCallCount == 1)
        await gate.open()
        await first.value
        await second.value

        #expect(sut.loadingState == .loaded)
        #expect(sut.shorts.count == 2)
        await sut.load()
        #expect(client.shortsCallCount == 1)

        client.gate = nil
        await sut.refresh()
        #expect(client.shortsCallCount == 2)
    }

    @Test("Explore concurrent loads coalesce and loaded load is a no-op")
    func exploreLoadCoalescesAndNoOpsWhenLoaded() async {
        let client = SingleFlightYouTubeClient()
        client.destinationFeed = YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil)
        let gate = AsyncGate()
        client.gate = gate
        let sut = YouTubeExploreViewModel(client: client)
        sut.selectedDestination = .news

        let first = Task { await sut.load() }
        await self.waitUntil(client.destinationFeedCallCount == 1, "destination request started")
        let second = Task { await sut.load() }
        await Task.yield()
        first.cancel()
        await Task.yield()

        #expect(client.destinationFeedCallCount == 1)
        await gate.open()
        await first.value
        await second.value

        #expect(sut.loadingState == .loaded)
        #expect(sut.videos.count == 2)
        #expect(client.requestedDestinations == [.news])
        await sut.load()
        #expect(client.destinationFeedCallCount == 1)

        client.gate = nil
        await sut.refresh()
        #expect(client.destinationFeedCallCount == 2)
        #expect(client.requestedDestinations == [.news, .news])
    }

    @Test("Explore destination change cancels stale work and fetches the new selection")
    func exploreDestinationChangeStartsFreshLoad() async {
        let client = SingleFlightYouTubeClient()
        client.destinationFeed = YouTubeFeed(videos: [MockYouTubeClient.makeVideo(videoId: "selected")], continuation: nil)
        let gate = AsyncGate()
        client.gate = gate
        let sut = YouTubeExploreViewModel(client: client)
        sut.selectedDestination = .news

        let stale = Task { await sut.load() }
        await self.waitUntil(client.destinationFeedCallCount == 1, "stale destination request started")

        sut.selectedDestination = .sports
        client.gate = nil
        await sut.load()
        #expect(client.destinationFeedCallCount == 2)
        #expect(client.requestedDestinations == [.news, .sports])
        #expect(sut.loadingState == .loaded)
        #expect(sut.videos.map(\.videoId) == ["selected"])

        await gate.open()
        await stale.value
        #expect(sut.loadingState == .loaded)
        #expect(sut.videos.map(\.videoId) == ["selected"])
    }

    @Test("Store account reset cancels and replaces account-scoped view models")
    func storeResetCancelsAndReplacesAccountScopedViewModels() async {
        let client = SingleFlightYouTubeClient()
        client.historyFeed = YouTubeFeed(videos: [MockYouTubeClient.makeVideo(videoId: "new-account")], continuation: nil)
        let gate = AsyncGate()
        client.gate = gate
        let store = YouTubeViewModelStore(client: client)
        let oldHistory = store.history

        let staleLoad = Task { await oldHistory.load() }
        await self.waitUntil(client.historyCallCount == 1, "old history request started")

        store.resetForAccountChange()
        let newHistory = store.history

        #expect(ObjectIdentifier(oldHistory) != ObjectIdentifier(newHistory))

        client.gate = nil
        await newHistory.load()
        #expect(client.historyCallCount == 2)
        #expect(newHistory.loadingState == .loaded)
        #expect(newHistory.videos.map(\.videoId) == ["new-account"])

        await gate.open()
        await staleLoad.value
        #expect(newHistory.videos.map(\.videoId) == ["new-account"])
    }

    @Test("Playlists concurrent loads coalesce and refresh forces a reload")
    func playlistsLoadCoalescesAndRefreshes() async {
        let client = SingleFlightYouTubeClient()
        client.userPlaylists = [YouTubePlaylist(playlistId: "PL1", title: "One")]
        let gate = AsyncGate()
        client.gate = gate
        let sut = YouTubePlaylistsViewModel(client: client)

        let first = Task { await sut.load() }
        await self.waitUntil(client.userPlaylistsCallCount == 1, "playlists request started")
        let second = Task { await sut.load() }
        await Task.yield()
        first.cancel()
        await Task.yield()

        #expect(client.userPlaylistsCallCount == 1)
        await gate.open()
        await first.value
        await second.value

        #expect(sut.loadingState == .loaded)
        #expect(sut.playlists.map(\.playlistId) == ["PL1"])
        await sut.load()
        #expect(client.userPlaylistsCallCount == 1)

        client.gate = nil
        await sut.refresh()
        #expect(client.userPlaylistsCallCount == 2)
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, _ description: String) async {
        for _ in 0 ..< 1000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(description)")
    }
}

// MARK: - SingleFlightYouTubeClient

@MainActor
private final class SingleFlightYouTubeClient: YouTubeClientProtocol {
    var gate: AsyncGate?

    var homeFeed = YouTubeFeed.empty
    var homeBundle = YouTubeHomeBundle(feed: .empty, chips: [], shelves: [])
    var homeFeedContinuation: YouTubeFeed?
    var homeChips: [YouTubeHomeChip] = []
    var homeShelves: [YouTubeHomeSection] = []
    var homeTopicFeed = YouTubeFeed.empty
    var hasMoreHomeFeed = false

    var searchResponse = YouTubeSearchResponse.empty
    var searchContinuation: YouTubeSearchResponse?
    var watchNextData = WatchNextData.empty
    var commentsPage = YouTubeCommentsPage.empty
    var channelDetail: YouTubeChannelDetail?
    var playlistDetail: YouTubePlaylistDetail?
    var destinationFeed = YouTubeFeed.empty
    var shorts: [YouTubeVideo] = []
    var feedContinuation = YouTubeFeed.empty
    var subscriptionsFeed = YouTubeFeed.empty
    var subscribedChannels: [YouTubeChannel] = []
    var historyFeed = YouTubeFeed.empty
    var userPlaylists: [YouTubePlaylist] = []

    func resetSessionStateForAccountSwitch() {
        self.homeFeed = YouTubeFeed(videos: self.homeFeed.videos, continuation: nil)
        self.homeBundle = YouTubeHomeBundle(feed: YouTubeFeed(videos: self.homeBundle.feed.videos, continuation: nil), chips: self.homeBundle.chips, shelves: self.homeBundle.shelves)
        self.homeFeedContinuation = nil
        self.hasMoreHomeFeed = false
        self.searchContinuation = nil
    }

    private(set) var historyCallCount = 0
    private(set) var subscriptionsFeedCallCount = 0
    private(set) var subscribedChannelsCallCount = 0
    private(set) var shortsCallCount = 0
    private(set) var destinationFeedCallCount = 0
    private(set) var requestedDestinations: [YouTubeDestination] = []
    private(set) var channelCallCount = 0
    private(set) var playlistCallCount = 0
    private(set) var userPlaylistsCallCount = 0

    func getHomeFeed() async throws -> YouTubeFeed {
        try await self.waitIfNeeded()
        return self.homeFeed
    }

    func getHomeBundle() async throws -> YouTubeHomeBundle {
        try await self.waitIfNeeded()
        return self.homeBundle
    }

    func getHomeFeedContinuation() async throws -> YouTubeFeed? {
        try await self.waitIfNeeded()
        let continuation = self.homeFeedContinuation
        self.homeFeedContinuation = nil
        return continuation
    }

    func getHomeChips() async throws -> [YouTubeHomeChip] {
        try await self.waitIfNeeded()
        return self.homeChips
    }

    func getHomeShelves() async throws -> [YouTubeHomeSection] {
        try await self.waitIfNeeded()
        return self.homeShelves
    }

    func getHomeTopicFeed(continuation _: String) async throws -> YouTubeFeed {
        try await self.waitIfNeeded()
        return self.homeTopicFeed
    }

    func search(query _: String, filter _: YouTubeSearchFilter) async throws -> YouTubeSearchResponse {
        try await self.waitIfNeeded()
        return self.searchResponse
    }

    func getSearchContinuation() async throws -> YouTubeSearchResponse? {
        guard let currentContinuation = self.searchContinuation?.continuation else { return nil }
        return try await self.getSearchContinuation(continuation: currentContinuation)
    }

    func getSearchContinuation(continuation _: String) async throws -> YouTubeSearchResponse? {
        try await self.waitIfNeeded()
        let continuation = self.searchContinuation
        self.searchContinuation = nil
        return continuation
    }

    func getWatchNext(videoId _: String) async throws -> WatchNextData {
        try await self.waitIfNeeded()
        return self.watchNextData
    }

    func getComments(continuation _: String) async throws -> YouTubeCommentsPage {
        try await self.waitIfNeeded()
        return self.commentsPage
    }

    func postComment(text _: String, createCommentParams _: String) async throws {
        try await self.waitIfNeeded()
    }

    func performCommentAction(_: String) async throws {
        try await self.waitIfNeeded()
    }

    func getChannel(channelId: String) async throws -> YouTubeChannelDetail {
        self.channelCallCount += 1
        try await self.waitIfNeeded()
        if let channelDetail { return channelDetail }
        return YouTubeChannelDetail(channel: YouTubeChannel(channelId: channelId, name: "Mock Channel"), videos: [])
    }

    func getPlaylist(playlistId: String) async throws -> YouTubePlaylistDetail {
        self.playlistCallCount += 1
        try await self.waitIfNeeded()
        if let playlistDetail { return playlistDetail }
        return YouTubePlaylistDetail(playlist: YouTubePlaylist(playlistId: playlistId, title: "Mock Playlist"), videos: [])
    }

    func getDestinationFeed(_ destination: YouTubeDestination) async throws -> YouTubeFeed {
        self.destinationFeedCallCount += 1
        self.requestedDestinations.append(destination)
        try await self.waitIfNeeded()
        return self.destinationFeed
    }

    func getShorts() async throws -> [YouTubeVideo] {
        self.shortsCallCount += 1
        try await self.waitIfNeeded()
        return self.shorts
    }

    func getFeedContinuation(continuation _: String) async throws -> YouTubeFeed {
        try await self.waitIfNeeded()
        return self.feedContinuation
    }

    func getPrivateFeedContinuation(continuation: String) async throws -> YouTubeFeed {
        try await self.getFeedContinuation(continuation: continuation)
    }

    func getSubscriptionsFeed() async throws -> YouTubeFeed {
        self.subscriptionsFeedCallCount += 1
        try await self.waitIfNeeded()
        return self.subscriptionsFeed
    }

    func getSubscribedChannels() async throws -> [YouTubeChannel] {
        self.subscribedChannelsCallCount += 1
        try await self.waitIfNeeded()
        return self.subscribedChannels
    }

    func getHistory(forceRefresh _: Bool) async throws -> YouTubeFeed {
        self.historyCallCount += 1
        try await self.waitIfNeeded()
        return self.historyFeed
    }

    func getUserPlaylists() async throws -> [YouTubePlaylist] {
        self.userPlaylistsCallCount += 1
        try await self.waitIfNeeded()
        return self.userPlaylists
    }

    func rateVideo(videoId _: String, rating _: YouTubeRating) async throws {
        try await self.waitIfNeeded()
    }

    func setSubscribed(_: Bool, channelId _: String) async throws {
        try await self.waitIfNeeded()
    }

    func addToWatchLater(videoId _: String) async throws {
        try await self.waitIfNeeded()
    }

    func removeFromWatchLater(videoId _: String) async throws {
        try await self.waitIfNeeded()
    }

    private func waitIfNeeded() async throws {
        if Task.isCancelled {
            throw CancellationError()
        }
        if let gate {
            await gate.wait()
        }
        if Task.isCancelled {
            throw CancellationError()
        }
    }
}
