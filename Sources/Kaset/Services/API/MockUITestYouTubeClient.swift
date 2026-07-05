import Foundation

/// A mock implementation of YouTubeClientProtocol for UI testing.
/// Returns deterministic fixture data so UI tests never hit the network.
@MainActor
final class MockUITestYouTubeClient: YouTubeClientProtocol {
    var hasMoreHomeFeed: Bool {
        false
    }

    func resetSessionStateForAccountSwitch() {}

    func getHomeFeed() async throws -> YouTubeFeed {
        YouTubeFeed(videos: Self.sampleVideos, continuation: nil)
    }

    func getHomeBundle() async throws -> YouTubeHomeBundle {
        try await YouTubeHomeBundle(
            feed: self.getHomeFeed(),
            chips: self.getHomeChips(),
            shelves: self.getHomeShelves()
        )
    }

    func getHomeFeedContinuation() async throws -> YouTubeFeed? {
        nil
    }

    func getHomeChips() async throws -> [YouTubeHomeChip] {
        [
            YouTubeHomeChip(title: "Gaming", continuation: "mock-chip-gaming"),
            YouTubeHomeChip(title: "Music", continuation: "mock-chip-music"),
        ]
    }

    func getHomeShelves() async throws -> [YouTubeHomeSection] {
        [
            YouTubeHomeSection(
                id: "shelf-1-Breaking news",
                title: "Breaking news",
                videos: Self.sampleVideos,
                kind: .shelf
            ),
        ]
    }

    func getHomeTopicFeed(continuation _: String) async throws -> YouTubeFeed {
        YouTubeFeed(videos: Self.sampleVideos, continuation: nil)
    }

    func search(query _: String, filter: YouTubeSearchFilter) async throws -> YouTubeSearchResponse {
        switch filter {
        case .all:
            YouTubeSearchResponse(
                videos: Self.sampleVideos,
                channels: [Self.sampleChannel],
                playlists: [Self.samplePlaylist],
                continuation: nil
            )
        case .videos:
            YouTubeSearchResponse(
                videos: Self.sampleVideos,
                channels: [],
                playlists: [],
                continuation: nil
            )
        case .channels:
            YouTubeSearchResponse(
                videos: [],
                channels: [Self.sampleChannel],
                playlists: [],
                continuation: nil
            )
        case .playlists:
            YouTubeSearchResponse(
                videos: [],
                channels: [],
                playlists: [Self.samplePlaylist],
                continuation: nil
            )
        }
    }

    func getSearchContinuation() async throws -> YouTubeSearchResponse? {
        nil
    }

    func getSearchContinuation(continuation _: String) async throws -> YouTubeSearchResponse? {
        nil
    }

    func getWatchNext(videoId _: String) async throws -> WatchNextData {
        WatchNextData(
            videoTitle: "Mock Video One",
            viewCountText: "1,234 views",
            publishedText: "1 day ago",
            channel: Self.sampleChannel,
            related: Array(Self.sampleVideos.dropFirst())
        )
    }

    func getComments(continuation _: String) async throws -> YouTubeCommentsPage {
        YouTubeCommentsPage(
            comments: [
                YouTubeComment(
                    id: "mock-comment-1",
                    author: "Mock Commenter",
                    authorAvatarURL: nil,
                    text: "Great video!",
                    publishedText: "1 day ago",
                    likeCountText: "12"
                ),
            ],
            continuation: nil,
            createCommentParams: "mock-create-params"
        )
    }

    func postComment(text _: String, createCommentParams _: String) async throws {}

    func performCommentAction(_: String) async throws {}

    func getChannel(channelId: String) async throws -> YouTubeChannelDetail {
        YouTubeChannelDetail(
            channel: YouTubeChannel(
                channelId: channelId,
                name: Self.sampleChannel.name,
                handle: Self.sampleChannel.handle,
                subscriberCountText: Self.sampleChannel.subscriberCountText
            ),
            videos: Self.sampleVideos
        )
    }

    func getPlaylist(playlistId: String) async throws -> YouTubePlaylistDetail {
        YouTubePlaylistDetail(
            playlist: YouTubePlaylist(
                playlistId: playlistId,
                title: "Mock Playlist",
                channelName: Self.sampleChannel.name,
                videoCountText: "3 videos"
            ),
            videos: Self.sampleVideos
        )
    }

    func getDestinationFeed(_: YouTubeDestination) async throws -> YouTubeFeed {
        YouTubeFeed(videos: Self.sampleVideos, continuation: nil)
    }

    func getShorts() async throws -> [YouTubeVideo] {
        [
            YouTubeVideo(videoId: "mock-short-1", title: "Mock Short One", viewCountText: "1M views", isShort: true),
            YouTubeVideo(videoId: "mock-short-2", title: "Mock Short Two", viewCountText: "2M views", isShort: true),
        ]
    }

    func getFeedContinuation(continuation _: String) async throws -> YouTubeFeed {
        .empty
    }

    func getPrivateFeedContinuation(continuation _: String) async throws -> YouTubeFeed {
        .empty
    }

    func getSubscriptionsFeed() async throws -> YouTubeFeed {
        YouTubeFeed(videos: Self.sampleVideos, continuation: nil)
    }

    func getSubscribedChannels() async throws -> [YouTubeChannel] {
        [Self.sampleChannel]
    }

    func getHistory(forceRefresh _: Bool) async throws -> YouTubeFeed {
        YouTubeFeed(videos: Self.sampleHistoryVideos, continuation: nil)
    }

    func getUserPlaylists() async throws -> [YouTubePlaylist] {
        [Self.samplePlaylist]
    }

    func rateVideo(videoId _: String, rating _: YouTubeRating) async throws {}

    func setSubscribed(_: Bool, channelId _: String) async throws {}

    func addToWatchLater(videoId _: String) async throws {}

    func removeFromWatchLater(videoId _: String) async throws {}

    // MARK: - Sample Data

    private static let sampleVideos = [
        YouTubeVideo(
            videoId: "mock-video-1",
            title: "Mock Video One",
            channelName: "Mock Channel",
            channelId: "UCmockchannel",
            lengthText: "10:00",
            viewCountText: "1K views",
            publishedText: "1 day ago"
        ),
        YouTubeVideo(
            videoId: "mock-video-2",
            title: "Mock Video Two",
            channelName: "Mock Channel",
            channelId: "UCmockchannel",
            lengthText: "5:30",
            viewCountText: "2K views",
            publishedText: "2 days ago"
        ),
        YouTubeVideo(
            videoId: "mock-video-3",
            title: "Mock Video Three",
            channelName: "Another Channel",
            channelId: "UCanotherchannel",
            lengthText: "1:02:03",
            viewCountText: "3K views",
            publishedText: "3 days ago"
        ),
    ]

    /// History fixture including partially-watched videos so the Continue
    /// Watching rail renders under UI-test mode (watchedPercent within 1…95).
    private static let sampleHistoryVideos = [
        YouTubeVideo(
            videoId: "mock-history-1",
            title: "Mock History One",
            channelName: "Mock Channel",
            channelId: "UCmockchannel",
            lengthText: "12:00",
            viewCountText: "5K views",
            publishedText: "1 day ago",
            watchedPercent: 35
        ),
        YouTubeVideo(
            videoId: "mock-history-2",
            title: "Mock History Two",
            channelName: "Another Channel",
            channelId: "UCanotherchannel",
            lengthText: "8:20",
            viewCountText: "9K views",
            publishedText: "2 days ago",
            watchedPercent: 80
        ),
        // Fully watched: excluded from Continue Watching, present in history.
        YouTubeVideo(
            videoId: "mock-history-3",
            title: "Mock History Three",
            channelName: "Mock Channel",
            channelId: "UCmockchannel",
            lengthText: "4:10",
            viewCountText: "1K views",
            publishedText: "3 days ago",
            watchedPercent: 100
        ),
    ]

    private static let sampleChannel = YouTubeChannel(
        channelId: "UCmockchannel",
        name: "Mock Channel",
        handle: "@mockchannel",
        subscriberCountText: "10K subscribers"
    )

    private static let samplePlaylist = YouTubePlaylist(
        playlistId: "PLmockplaylist",
        title: "Mock Playlist",
        channelName: "Mock Channel",
        videoCountText: "3 videos",
        firstVideoId: "mock-video-1"
    )
}
