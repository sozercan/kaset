import Foundation

// MARK: - YouTubeClientProtocol

/// Protocol for the regular YouTube (video) API client.
///
/// Parallel to `YTMusicClientProtocol` but mapped to YouTube's content
/// model (videos, channels, subscriptions) rather than YouTube Music's
/// (songs, albums, artists). Enables dependency injection and mocking.
@MainActor
protocol YouTubeClientProtocol: Sendable {
    // MARK: Home feed

    /// Fetches the recommended home feed (`FEwhat_to_watch`).
    func getHomeFeed() async throws -> YouTubeFeed

    /// Fetches the next page of the home feed, or `nil` when exhausted.
    func getHomeFeedContinuation() async throws -> YouTubeFeed?

    /// Whether more home feed pages are available.
    var hasMoreHomeFeed: Bool { get }

    // MARK: Search

    /// Searches YouTube with an optional result-kind filter.
    func search(query: String, filter: YouTubeSearchFilter) async throws -> YouTubeSearchResponse

    /// Fetches the next page of the current search, or `nil` when exhausted.
    func getSearchContinuation() async throws -> YouTubeSearchResponse?

    // MARK: Watch

    /// Fetches watch-page companion data (metadata + related videos).
    func getWatchNext(videoId: String) async throws -> WatchNextData

    // MARK: Browse

    /// Fetches a channel page by `UC…` channel ID.
    func getChannel(channelId: String) async throws -> YouTubeChannelDetail

    /// Fetches a playlist page by playlist ID (without the `VL` prefix).
    func getPlaylist(playlistId: String) async throws -> YouTubePlaylistDetail
}
