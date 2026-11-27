import Foundation

@MainActor
protocol YouTubeClientProtocol: Sendable {
    func resetSessionStateForAccountSwitch()

    func getHomeFeed() async throws -> YouTubeFeed

    func getHomeBundle(forceRefresh: Bool) async throws -> YouTubeHomeBundle

    func getHomeFeedContinuation() async throws -> YouTubeFeed?

    var hasMoreHomeFeed: Bool { get }

    func getHomeChips() async throws -> [YouTubeHomeChip]

    func getHomeShelves() async throws -> [YouTubeHomeSection]

    func getHomeTopicFeed(continuation: String, forceRefresh: Bool) async throws -> YouTubeFeed

    func search(query: String, filter: YouTubeSearchFilter) async throws -> YouTubeSearchResponse

    func getSearchContinuation() async throws -> YouTubeSearchResponse?

    func getSearchContinuation(continuation: String) async throws -> YouTubeSearchResponse?

    func getWatchNext(videoId: String) async throws -> WatchNextData

    func getWatchPage(videoId: String) async throws -> YouTubeWatchPage

    func loadAskConversation(
        from bootstrap: YouTubeAskBootstrap
    ) async throws -> YouTubeAskConversation

    func continueAskConversation(
        _ conversation: YouTubeAskConversation,
        selecting suggestionID: YouTubeAskSuggestion.ID
    ) async throws -> YouTubeAskConversation

    func continueAskConversation(
        _ conversation: YouTubeAskConversation,
        submitting userInputText: String,
        playerOffsetMilliseconds: Int64
    ) async throws -> YouTubeAskConversation

    func getComments(continuation: String) async throws -> YouTubeCommentsPage

    func postComment(text: String, createCommentParams: String) async throws

    func performCommentAction(_ action: String) async throws

    func getChannel(channelId: String) async throws -> YouTubeChannelDetail

    func getPlaylist(playlistId: String) async throws -> YouTubePlaylistDetail

    func getDestinationFeed(_ destination: YouTubeDestination) async throws -> YouTubeFeed

    func getShorts() async throws -> [YouTubeVideo]

    func getFeedContinuation(continuation: String) async throws -> YouTubeFeed

    func getPrivateFeedContinuation(continuation: String) async throws -> YouTubeFeed

    func getSubscriptionsFeed() async throws -> YouTubeFeed

    func getSubscribedChannels() async throws -> [YouTubeChannel]

    func getHistory(forceRefresh: Bool) async throws -> YouTubeFeed

    func getUserPlaylists() async throws -> [YouTubePlaylist]

    func rateVideo(videoId: String, rating: YouTubeRating) async throws

    func setSubscribed(_ subscribed: Bool, channelId: String) async throws

    func addToWatchLater(videoId: String) async throws

    func removeFromWatchLater(videoId: String) async throws
}

extension YouTubeClientProtocol {
    func getHistory() async throws -> YouTubeFeed {
        try await self.getHistory(forceRefresh: false)
    }
}
