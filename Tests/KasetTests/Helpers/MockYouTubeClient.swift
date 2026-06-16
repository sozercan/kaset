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

    var hasMoreHomeFeed: Bool {
        // When a multi-page queue is configured it drives "has more"; otherwise
        // fall back to the single-page `homeFeedContinuation`.
        if !self.homeContinuationPages.isEmpty {
            return true
        }
        return self.homeFeedContinuation != nil
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

    func getHomeFeedContinuation() async throws -> YouTubeFeed? {
        if let error { throw error }
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

    func search(query: String, filter: YouTubeSearchFilter) async throws -> YouTubeSearchResponse {
        if let error { throw error }
        self.searchCallCount += 1
        self.lastSearchQuery = query
        self.lastSearchFilter = filter
        return self.searchResponse
    }

    func getSearchContinuation() async throws -> YouTubeSearchResponse? {
        if let error { throw error }
        let continuation = self.searchContinuation
        self.searchContinuation = nil
        return continuation
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

    var shorts: [YouTubeVideo] = []

    func getDestinationFeed(_ destination: YouTubeDestination) async throws -> YouTubeFeed {
        if let error { throw error }
        self.lastDestination = destination
        return self.destinationFeed
    }

    func getShorts() async throws -> [YouTubeVideo] {
        if let error { throw error }
        return self.shorts
    }

    func getFeedContinuation(continuation: String) async throws -> YouTubeFeed {
        if let error { throw error }
        self.lastFeedContinuation = continuation
        return self.feedContinuation
    }

    func getSubscriptionsFeed() async throws -> YouTubeFeed {
        if let error { throw error }
        return self.subscriptionsFeed
    }

    func getSubscribedChannels() async throws -> [YouTubeChannel] {
        if let error { throw error }
        return self.subscribedChannels
    }

    func getHistory() async throws -> YouTubeFeed {
        if let error { throw error }
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
