import Foundation

// MARK: - YouTubeFeed

/// A page of the YouTube home (recommended) feed.
struct YouTubeFeed {
    let videos: [YouTubeVideo]
    /// Shorts found in the response, kept separate so the regular feed
    /// grids stay uniform; surfaced on the dedicated Shorts page.
    let shorts: [YouTubeVideo]
    let continuation: String?

    init(videos: [YouTubeVideo], shorts: [YouTubeVideo] = [], continuation: String?) {
        self.videos = videos
        self.shorts = shorts
        self.continuation = continuation
    }

    static let empty = YouTubeFeed(videos: [], continuation: nil)
}

// MARK: - YouTubeSearchResponse

/// Results of a YouTube search, split by result kind.
struct YouTubeSearchResponse {
    var videos: [YouTubeVideo]
    var channels: [YouTubeChannel]
    var playlists: [YouTubePlaylist]
    var continuation: String?

    static let empty = YouTubeSearchResponse(
        videos: [],
        channels: [],
        playlists: [],
        continuation: nil
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
    /// Continuation token for the video's comments section.
    var commentsContinuation: String?

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

// MARK: - YouTubeComment

/// A comment on a YouTube video.
struct YouTubeComment: Identifiable, Hashable {
    let id: String
    let author: String
    let authorAvatarURL: URL?
    let text: String
    let publishedText: String?
    let likeCountText: String?
    /// The author's channel (for navigation to their page).
    var authorChannelId: String?
    /// Action token for liking this comment.
    var likeAction: String?
    /// Action token for removing a like.
    var unlikeAction: String?
    /// Action token for disliking this comment.
    var dislikeAction: String?
    /// Action token for removing a dislike.
    var undislikeAction: String?
    /// Continuation token for this comment's reply thread.
    var repliesContinuation: String?

    init(
        id: String,
        author: String,
        authorAvatarURL: URL?,
        text: String,
        publishedText: String?,
        likeCountText: String?,
        authorChannelId: String? = nil,
        likeAction: String? = nil,
        unlikeAction: String? = nil,
        dislikeAction: String? = nil,
        undislikeAction: String? = nil,
        repliesContinuation: String? = nil
    ) {
        self.id = id
        self.author = author
        self.authorAvatarURL = authorAvatarURL
        self.text = text
        self.publishedText = publishedText
        self.likeCountText = likeCountText
        self.authorChannelId = authorChannelId
        self.likeAction = likeAction
        self.unlikeAction = unlikeAction
        self.dislikeAction = dislikeAction
        self.undislikeAction = undislikeAction
        self.repliesContinuation = repliesContinuation
    }
}

// MARK: - YouTubeCommentsPage

/// One page of a video's comments.
struct YouTubeCommentsPage {
    let comments: [YouTubeComment]
    /// Token for the next page (nil when exhausted).
    let continuation: String?
    /// Params for posting a top-level comment (nil when signed out or
    /// comments are disabled).
    let createCommentParams: String?

    static let empty = YouTubeCommentsPage(comments: [], continuation: nil, createCommentParams: nil)
}

// MARK: - YouTubeCaptionTrack

/// A caption track offered by the watch page player.
struct YouTubeCaptionTrack: Identifiable, Hashable {
    let languageCode: String
    let displayName: String

    var id: String {
        self.languageCode
    }
}

// MARK: - YouTubeQuality

/// Display helpers for YouTube's quality-level identifiers.
enum YouTubeQuality {
    /// Human-readable name for a player quality level (e.g. "hd1080" → "1080p").
    static func displayName(for level: String) -> String {
        switch level {
        case "highres": "4320p (8K)"
        case "hd2880": "2880p"
        case "hd2160": "2160p (4K)"
        case "hd1440": "1440p"
        case "hd1080": "1080p"
        case "hd720": "720p"
        case "large": "480p"
        case "medium": "360p"
        case "small": "240p"
        case "tiny": "144p"
        case "auto": String(localized: "Auto")
        default: level
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
