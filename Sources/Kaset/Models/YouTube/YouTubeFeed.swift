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
    /// Whether the signed-in user is subscribed to the video's channel
    /// (nil when the page did not expose a subscribe button).
    var isSubscribed: Bool?

    static let empty = WatchNextData(
        videoTitle: nil,
        viewCountText: nil,
        publishedText: nil,
        channel: nil,
        related: []
    )
}

// MARK: - YouTubeDestination

/// Public destination feeds shown on the Explore surface.
/// (YouTube retired the Trending feed in 2025; these are its successors.)
enum YouTubeDestination: String, CaseIterable, Identifiable {
    case gaming
    case news
    case sports
    case live
    case fashion
    case learning

    var id: String {
        rawValue
    }

    var browseId: String {
        "FE\(rawValue)_destination"
    }

    var displayName: String {
        switch self {
        case .gaming: String(localized: "Gaming")
        case .news: String(localized: "News")
        case .sports: String(localized: "Sports")
        case .live: String(localized: "Live")
        case .fashion: String(localized: "Fashion & Beauty")
        case .learning: String(localized: "Learning")
        }
    }
}

// MARK: - YouTubeRating

/// Rating actions for a video.
enum YouTubeRating {
    case like
    case dislike
    case none

    /// InnerTube action endpoint for this rating.
    var endpoint: String {
        switch self {
        case .like: "like/like"
        case .dislike: "like/dislike"
        case .none: "like/removelike"
        }
    }
}
