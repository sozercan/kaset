import Foundation

struct YouTubeFeed {
    let videos: [YouTubeVideo]
    let shorts: [YouTubeVideo]
    let continuation: String?

    init(videos: [YouTubeVideo], shorts: [YouTubeVideo] = [], continuation: String?) {
        self.videos = videos
        self.shorts = shorts
        self.continuation = continuation
    }

    static let empty = YouTubeFeed(videos: [], continuation: nil)
}

struct YouTubeHomeSection: Identifiable {
    enum Kind: Hashable {
        case continueWatching
        case shelf
        case topic
    }

    let id: String
    let title: String
    let videos: [YouTubeVideo]
    let kind: Kind
}

struct YouTubeHomeChip: Identifiable {
    var id: String {
        self.title
    }

    let title: String
    let continuation: String
}

struct YouTubeHomeBundle {
    let feed: YouTubeFeed
    let chips: [YouTubeHomeChip]
    let shelves: [YouTubeHomeSection]
}

struct YouTubeChapter: Identifiable, Hashable {
    let videoId: String?
    let title: String
    let startTime: TimeInterval
    let endTime: TimeInterval?
    let timeText: String?
    let thumbnailURL: URL?

    var id: String {
        "\(self.videoId ?? "")-\(Int((self.startTime * 1000).rounded()))-\(self.title)"
    }
}

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

struct WatchNextData {
    let videoTitle: String?
    let viewCountText: String?
    let publishedText: String?
    let channel: YouTubeChannel?
    let related: [YouTubeVideo]
    let chapters: [YouTubeChapter]
    let descriptionText: String?
    var isSubscribed: Bool?
    var commentsContinuation: String?

    init(
        videoTitle: String?,
        viewCountText: String?,
        publishedText: String?,
        channel: YouTubeChannel?,
        related: [YouTubeVideo],
        chapters: [YouTubeChapter] = [],
        descriptionText: String? = nil,
        isSubscribed: Bool? = nil,
        commentsContinuation: String? = nil
    ) {
        self.videoTitle = videoTitle
        self.viewCountText = viewCountText
        self.publishedText = publishedText
        self.channel = channel
        self.related = related
        self.chapters = chapters
        self.descriptionText = descriptionText
        self.isSubscribed = isSubscribed
        self.commentsContinuation = commentsContinuation
    }

    static let empty = WatchNextData(
        videoTitle: nil,
        viewCountText: nil,
        publishedText: nil,
        channel: nil,
        related: []
    )
}

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

struct YouTubeComment: Identifiable, Hashable {
    let id: String
    let author: String
    let authorAvatarURL: URL?
    let text: String
    let publishedText: String?
    let likeCountText: String?
    var authorChannelId: String?
    var likeAction: String?
    var unlikeAction: String?
    var dislikeAction: String?
    var undislikeAction: String?
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

struct YouTubeCommentsPage {
    let comments: [YouTubeComment]
    let continuation: String?
    let createCommentParams: String?

    static let empty = YouTubeCommentsPage(comments: [], continuation: nil, createCommentParams: nil)
}

struct YouTubeCaptionTrack: Identifiable, Hashable {
    let languageCode: String
    let displayName: String

    var id: String {
        self.languageCode
    }
}

enum YouTubeQuality {
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

enum YouTubeRating {
    case like
    case dislike
    case none

    var endpoint: String {
        switch self {
        case .like: "like/like"
        case .dislike: "like/dislike"
        case .none: "like/removelike"
        }
    }
}
