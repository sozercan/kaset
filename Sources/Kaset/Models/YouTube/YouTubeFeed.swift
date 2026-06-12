import Foundation

// MARK: - YouTubeFeed

/// A page of the YouTube home (recommended) feed.
struct YouTubeFeed {
    let videos: [YouTubeVideo]
    let continuationToken: String?

    static let empty = YouTubeFeed(videos: [], continuationToken: nil)
}

// MARK: - YouTubeSearchResponse

/// Results of a YouTube search, split by result kind.
struct YouTubeSearchResponse {
    var videos: [YouTubeVideo]
    var channels: [YouTubeChannel]
    var playlists: [YouTubePlaylist]
    var continuationToken: String?

    static let empty = YouTubeSearchResponse(
        videos: [],
        channels: [],
        playlists: [],
        continuationToken: nil
    )

    var isEmpty: Bool {
        self.videos.isEmpty && self.channels.isEmpty && self.playlists.isEmpty
    }
}

// MARK: - YouTubeSearchFilter

/// Search result filters mapped to InnerTube `params` values.
enum YouTubeSearchFilter: String, CaseIterable, Identifiable {
    case all
    case videos
    case channels
    case playlists

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .all:
            String(localized: "All")
        case .videos:
            String(localized: "Videos")
        case .channels:
            String(localized: "Channels")
        case .playlists:
            String(localized: "Playlists")
        }
    }

    /// InnerTube search `params` value for this filter (confirmed via api-explorer).
    var params: String? {
        switch self {
        case .all:
            nil
        case .videos:
            "EgIQAQ=="
        case .channels:
            "EgIQAg=="
        case .playlists:
            "EgIQAw=="
        }
    }
}

// MARK: - WatchNextData

/// Watch-page companion data from the `next` endpoint: video metadata and
/// the related-videos rail.
struct WatchNextData {
    let videoTitle: String?
    /// Full display view count, e.g. "29,754 views".
    let viewCountText: String?
    /// Relative publish date, e.g. "1 year ago".
    let publishedText: String?
    let channel: YouTubeChannel?
    let related: [YouTubeVideo]

    static let empty = WatchNextData(
        videoTitle: nil,
        viewCountText: nil,
        publishedText: nil,
        channel: nil,
        related: []
    )
}
