import Foundation

/// A mock implementation of YouTubeClientProtocol for UI testing.
/// Returns deterministic fixture data so UI tests never hit the network.
@MainActor
final class MockUITestYouTubeClient: YouTubeClientProtocol {
    var hasMoreHomeFeed: Bool {
        false
    }

    func getHomeFeed() async throws -> YouTubeFeed {
        YouTubeFeed(videos: Self.sampleVideos, continuationToken: nil)
    }

    func getHomeFeedContinuation() async throws -> YouTubeFeed? {
        nil
    }

    func search(query _: String, filter: YouTubeSearchFilter) async throws -> YouTubeSearchResponse {
        switch filter {
        case .all:
            YouTubeSearchResponse(
                videos: Self.sampleVideos,
                channels: [Self.sampleChannel],
                playlists: [Self.samplePlaylist],
                continuationToken: nil
            )
        case .videos:
            YouTubeSearchResponse(
                videos: Self.sampleVideos,
                channels: [],
                playlists: [],
                continuationToken: nil
            )
        case .channels:
            YouTubeSearchResponse(
                videos: [],
                channels: [Self.sampleChannel],
                playlists: [],
                continuationToken: nil
            )
        case .playlists:
            YouTubeSearchResponse(
                videos: [],
                channels: [],
                playlists: [Self.samplePlaylist],
                continuationToken: nil
            )
        }
    }

    func getSearchContinuation() async throws -> YouTubeSearchResponse? {
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
