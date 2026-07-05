import Foundation
@testable import Kaset

/// Configurable mock implementation of YouTubeClientProtocol for unit tests.
@MainActor
final class MockYouTubeClient: YouTubeClientProtocol {
    // MARK: - Configurable Responses

    var homeFeed = YouTubeFeed.empty
    var homeFeedContinuation: YouTubeFeed?
    var homeChips: [YouTubeHomeChip] = []
    var homeShelves: [YouTubeHomeSection] = []
    /// Topic feeds keyed by chip continuation; `getHomeTopicFeed` returns the
    /// match (or `.empty`). Set `homeTopicError` to make one continuation throw.
    var homeTopicFeeds: [String: YouTubeFeed] = [:]
    var homeTopicError: (continuation: String, error: Error)?
    var searchResponse = YouTubeSearchResponse.empty
    var searchResponsesByRequest: [String: YouTubeSearchResponse] = [:]
    var searchContinuation: YouTubeSearchResponse?
    var watchNextData = WatchNextData.empty
    var channelDetail: YouTubeChannelDetail?
    var playlistDetail: YouTubePlaylistDetail?

    /// When set, every call throws this error.
    var error: Error?

    // MARK: - Call Tracking

    private(set) var homeFeedCallCount = 0
    private(set) var searchCallCount = 0
    private(set) var lastSearchQuery: String?
    private(set) var lastSearchFilter: YouTubeSearchFilter?

    nonisolated static func searchKey(query: String, filter: YouTubeSearchFilter) -> String {
        "\(filter.rawValue)|\(query)"
    }

    var hasMoreHomeFeed: Bool {
        // When a multi-page queue is configured it drives "has more"; otherwise
        // fall back to the single-page `homeFeedContinuation`.
        if !self.homeContinuationPages.isEmpty {
            return true
        }
        return self.homeFeedContinuation != nil
    }

    func resetSessionStateForAccountSwitch() {
        self.homeFeed = YouTubeFeed(videos: self.homeFeed.videos, continuation: nil)
        self.homeFeedContinuation = nil
        self.homeContinuationPages = []
        self.searchContinuation = nil
    }

    /// Optional queue of continuation pages, consumed front-to-back by
    /// `getHomeFeedContinuation()`. Takes precedence over the single-page
    /// `homeFeedContinuation` when non-empty. Lets tests exercise multi-page
    /// pagination (e.g. a fully-filtered page followed by a page with videos).
    var homeContinuationPages: [YouTubeFeed] = []

    // MARK: - YouTubeClientProtocol

    func getHomeFeed() async throws -> YouTubeFeed {
        if let error { throw error }
        self.homeFeedCallCount += 1
        return self.homeFeed
    }

    func getHomeBundle() async throws -> YouTubeHomeBundle {
        if let error { throw error }
        // One call stands in for the single coalesced fetch: count it like a
        // home-feed fetch so call-count assertions read naturally, and assemble
        // the bundle from the same fixtures the individual getters use.
        self.homeFeedCallCount += 1
        return YouTubeHomeBundle(
            feed: self.homeFeed,
            chips: self.homeChips,
            shelves: self.homeShelves
        )
    }

    /// Awaited inside `getHomeFeedContinuation` before it returns, so a test can
    /// hold a pagination request open and assert behaviour while the model sits
    /// in `.loadingMore`.
    var beforeContinuationReturn: (@Sendable () async -> Void)?

    func getHomeFeedContinuation() async throws -> YouTubeFeed? {
        if let error { throw error }
        if let beforeContinuationReturn {
            await beforeContinuationReturn()
        }
        if !self.homeContinuationPages.isEmpty {
            return self.homeContinuationPages.removeFirst()
        }
        let continuation = self.homeFeedContinuation
        self.homeFeedContinuation = nil
        return continuation
    }

    private(set) var homeChipsCallCount = 0
    private(set) var requestedTopicContinuations: [String] = []

    func getHomeChips() async throws -> [YouTubeHomeChip] {
        if let error { throw error }
        self.homeChipsCallCount += 1
        return self.homeChips
    }

    func getHomeShelves() async throws -> [YouTubeHomeSection] {
        if let error { throw error }
        return self.homeShelves
    }

    /// Awaited inside `getHomeTopicFeed` before it returns, so a test can hold
    /// a topic rail open and observe that the home grid already rendered
    /// without waiting on the rail. Receives the chip continuation.
    var beforeTopicReturn: (@Sendable (String) async -> Void)?

    func getHomeTopicFeed(continuation: String) async throws -> YouTubeFeed {
        if let error { throw error }
        self.requestedTopicContinuations.append(continuation)
        if let beforeTopicReturn {
            await beforeTopicReturn(continuation)
        }
        if let homeTopicError, homeTopicError.continuation == continuation {
            throw homeTopicError.error
        }
        return self.homeTopicFeeds[continuation] ?? .empty
    }

    /// Awaited inside `search` before it returns, so a test can hold one
    /// search request open while a newer query/filter search completes first.
    var beforeSearchReturn: (@Sendable (String, YouTubeSearchFilter) async -> Void)?

    func search(query: String, filter: YouTubeSearchFilter) async throws -> YouTubeSearchResponse {
        if let error { throw error }
        self.searchCallCount += 1
        self.lastSearchQuery = query
        self.lastSearchFilter = filter
        if let beforeSearchReturn {
            await beforeSearchReturn(query, filter)
        }
        let key = Self.searchKey(query: query, filter: filter)
        return self.searchResponsesByRequest[key] ?? self.searchResponse
    }

    /// Awaited inside `getSearchContinuation` before it returns, so a test can
    /// hold a pagination request open while a newer search replaces results.
    var beforeSearchContinuationReturn: (@Sendable () async -> Void)?

    func getSearchContinuation() async throws -> YouTubeSearchResponse? {
        guard let currentContinuation = self.searchContinuation?.continuation else { return nil }
        return try await self.getSearchContinuation(continuation: currentContinuation)
    }

    func getSearchContinuation(continuation _: String) async throws -> YouTubeSearchResponse? {
        if let error { throw error }
        let response = self.searchContinuation
        if let beforeSearchContinuationReturn {
            await beforeSearchContinuationReturn()
        }
        if self.searchContinuation?.continuation == response?.continuation {
            self.searchContinuation = nil
        }
        return response
    }

    func getWatchNext(videoId _: String) async throws -> WatchNextData {
        if let error { throw error }
        return self.watchNextData
    }

    var commentsPage = YouTubeCommentsPage.empty
    private(set) var postedComments: [(text: String, params: String)] = []
    private(set) var lastCommentsContinuation: String?

    func getComments(continuation: String) async throws -> YouTubeCommentsPage {
        if let error { throw error }
        self.lastCommentsContinuation = continuation
        return self.commentsPage
    }

    func postComment(text: String, createCommentParams: String) async throws {
        if let error { throw error }
        self.postedComments.append((text, createCommentParams))
    }

    private(set) var performedCommentActions: [String] = []

    func performCommentAction(_ action: String) async throws {
        if let error { throw error }
        self.performedCommentActions.append(action)
    }

    func getChannel(channelId: String) async throws -> YouTubeChannelDetail {
        if let error { throw error }
        if let channelDetail { return channelDetail }
        return YouTubeChannelDetail(
            channel: YouTubeChannel(channelId: channelId, name: "Mock Channel"),
            videos: []
        )
    }

    func getPlaylist(playlistId: String) async throws -> YouTubePlaylistDetail {
        if let error { throw error }
        if let playlistDetail { return playlistDetail }
        return YouTubePlaylistDetail(
            playlist: YouTubePlaylist(playlistId: playlistId, title: "Mock Playlist"),
            videos: []
        )
    }

    var destinationFeed = YouTubeFeed.empty
    var feedContinuation = YouTubeFeed.empty
    var subscriptionsFeed = YouTubeFeed.empty
    var subscribedChannels: [YouTubeChannel] = []
    var historyFeed = YouTubeFeed.empty
    var userPlaylists: [YouTubePlaylist] = []

    private(set) var ratedVideos: [(videoId: String, rating: YouTubeRating)] = []
    private(set) var subscriptionChanges: [(channelId: String, subscribed: Bool)] = []
    private(set) var watchLaterAdds: [String] = []
    private(set) var watchLaterRemovals: [String] = []
    private(set) var lastDestination: YouTubeDestination?
    private(set) var lastFeedContinuation: String?
    private(set) var destinationFeedCallCount = 0
    private(set) var shortsCallCount = 0

    var shorts: [YouTubeVideo] = []

    func getDestinationFeed(_ destination: YouTubeDestination) async throws -> YouTubeFeed {
        if let error { throw error }
        self.destinationFeedCallCount += 1
        self.lastDestination = destination
        return self.destinationFeed
    }

    func getShorts() async throws -> [YouTubeVideo] {
        if let error { throw error }
        self.shortsCallCount += 1
        return self.shorts
    }

    func getFeedContinuation(continuation: String) async throws -> YouTubeFeed {
        if let error { throw error }
        self.lastFeedContinuation = continuation
        return self.feedContinuation
    }

    func getPrivateFeedContinuation(continuation: String) async throws -> YouTubeFeed {
        try await self.getFeedContinuation(continuation: continuation)
    }

    func getSubscriptionsFeed() async throws -> YouTubeFeed {
        if let error { throw error }
        return self.subscriptionsFeed
    }

    func getSubscribedChannels() async throws -> [YouTubeChannel] {
        if let error { throw error }
        return self.subscribedChannels
    }

    /// Awaited inside `getHistory` before it returns, so a test can hold the
    /// Continue Watching (history) request open and verify topic rails publish
    /// without waiting for it.
    var beforeHistoryReturn: (@Sendable () async -> Void)?

    /// Number of `getHistory` calls and how many requested a forced refresh,
    /// so tests can assert the Continue Watching rebuild bypasses the cache.
    private(set) var getHistoryCallCount = 0
    private(set) var getHistoryForceRefreshCount = 0

    /// When set, `getHistory(forceRefresh: true)` throws this — without failing
    /// the cached (initial-load) path — so a test can simulate a transient
    /// failure of only the post-watch refresh.
    var historyForceRefreshError: Error?

    /// When set, `getHistory(forceRefresh: true)` returns this instead of
    /// `historyFeed`, so a test can give the forced (post-watch) refresh
    /// different data than the cached initial load — making the rebuild a
    /// deterministic single `.updated` (no retry).
    var historyForceRefreshFeed: YouTubeFeed?

    func getHistory(forceRefresh: Bool) async throws -> YouTubeFeed {
        if let error { throw error }
        self.getHistoryCallCount += 1
        if forceRefresh {
            self.getHistoryForceRefreshCount += 1
            if let historyForceRefreshError {
                throw historyForceRefreshError
            }
        }
        if let beforeHistoryReturn {
            await beforeHistoryReturn()
        }
        if forceRefresh, let historyForceRefreshFeed {
            return historyForceRefreshFeed
        }
        return self.historyFeed
    }

    func getUserPlaylists() async throws -> [YouTubePlaylist] {
        if let error { throw error }
        return self.userPlaylists
    }

    func rateVideo(videoId: String, rating: YouTubeRating) async throws {
        if let error { throw error }
        self.ratedVideos.append((videoId, rating))
    }

    func setSubscribed(_ subscribed: Bool, channelId: String) async throws {
        if let error { throw error }
        self.subscriptionChanges.append((channelId, subscribed))
    }

    func addToWatchLater(videoId: String) async throws {
        if let error { throw error }
        self.watchLaterAdds.append(videoId)
    }

    func removeFromWatchLater(videoId: String) async throws {
        if let error { throw error }
        self.watchLaterRemovals.append(videoId)
    }

    // MARK: - Factories

    nonisolated static func makeVideo(
        videoId: String = "test-video",
        title: String = "Test Video",
        channelName: String = "Test Channel",
        isLive: Bool = false,
        isShort: Bool = false,
        watchedPercent: Int? = nil
    ) -> YouTubeVideo {
        YouTubeVideo(
            videoId: videoId,
            title: title,
            channelName: channelName,
            channelId: "UCtest",
            lengthText: isLive ? nil : "10:00",
            viewCountText: "1K views",
            publishedText: "1 day ago",
            isLive: isLive,
            isShort: isShort,
            watchedPercent: watchedPercent
        )
    }

    nonisolated static func makeVideos(count: Int) -> [YouTubeVideo] {
        (0 ..< count).map { index in
            self.makeVideo(videoId: "video-\(index)", title: "Video \(index)")
        }
    }
}
