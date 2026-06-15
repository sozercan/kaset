import Foundation
@testable import Kaset

/// Configurable mock implementation of YouTubeClientProtocol for unit tests.
@MainActor
final class MockYouTubeClient: YouTubeClientProtocol {
    // MARK: - Configurable Responses

    var homeFeed = YouTubeFeed.empty
    var homeFeedContinuation: YouTubeFeed?
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
        self.homeFeedContinuation != nil
    }

    // MARK: - YouTubeClientProtocol

    func getHomeFeed() async throws -> YouTubeFeed {
        if let error { throw error }
        self.homeFeedCallCount += 1
        return self.homeFeed
    }

    func getHomeFeedContinuation() async throws -> YouTubeFeed? {
        if let error { throw error }
        let continuation = self.homeFeedContinuation
        self.homeFeedContinuation = nil
        return continuation
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
        channelName: String = "Test Channel"
    ) -> YouTubeVideo {
        YouTubeVideo(
            videoId: videoId,
            title: title,
            channelName: channelName,
            channelId: "UCtest",
            lengthText: "10:00",
            viewCountText: "1K views",
            publishedText: "1 day ago"
        )
    }

    nonisolated static func makeVideos(count: Int) -> [YouTubeVideo] {
        (0 ..< count).map { index in
            self.makeVideo(videoId: "video-\(index)", title: "Video \(index)")
        }
    }
}
