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
