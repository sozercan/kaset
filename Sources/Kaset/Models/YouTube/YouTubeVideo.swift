import Foundation

struct YouTubeVideo: Identifiable, Hashable {
    let videoId: String
    let title: String
    let channelName: String?
    let channelId: String?
    let lengthText: String?
    let viewCountText: String?
    let publishedText: String?
    let thumbnailURL: URL?
    let isLive: Bool
    let isShort: Bool
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
