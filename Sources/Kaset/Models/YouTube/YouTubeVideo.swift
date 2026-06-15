import Foundation

/// A regular YouTube video as it appears in feeds, search results, and
/// related lists.
///
/// Distinct from `Song`: YouTube's content model has no album/artist
/// metadata — videos belong to channels and carry display-ready strings
/// (view counts, relative dates) rather than structured values.
struct YouTubeVideo: Identifiable, Hashable {
    let videoId: String
    let title: String
    let channelName: String?
    let channelId: String?
    /// Display duration, e.g. "28:01". `nil` for live streams.
    let lengthText: String?
    /// Short display view count, e.g. "29K views".
    let viewCountText: String?
    /// Relative publish date, e.g. "1 year ago".
    let publishedText: String?
    let thumbnailURL: URL?
    let isLive: Bool
    /// Whether this is a YouTube Short (vertical, ≤60s).
    let isShort: Bool
    /// Percent of the video the signed-in user has already watched (0–100),
    /// when YouTube reports resume progress. `nil` when unwatched or unavailable.
    let watchedPercent: Int?

    var id: String {
        self.videoId
    }

    init(
        videoId: String,
        title: String,
        channelName: String? = nil,
        channelId: String? = nil,
        lengthText: String? = nil,
        viewCountText: String? = nil,
        publishedText: String? = nil,
        thumbnailURL: URL? = nil,
        isLive: Bool = false,
        isShort: Bool = false,
        watchedPercent: Int? = nil
    ) {
        self.videoId = videoId
        self.title = title
        self.channelName = channelName
        self.channelId = channelId
        self.lengthText = lengthText
        self.viewCountText = viewCountText
        self.publishedText = publishedText
        self.thumbnailURL = thumbnailURL
        self.isLive = isLive
        self.isShort = isShort
        self.watchedPercent = watchedPercent
    }
}
