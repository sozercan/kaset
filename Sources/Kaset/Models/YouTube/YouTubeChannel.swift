import Foundation

// MARK: - YouTubeChannel

/// A YouTube channel as it appears in search results and on watch pages.
struct YouTubeChannel: Identifiable, Hashable {
    let channelId: String
    let name: String
    /// Channel handle, e.g. "@veritasium".
    let handle: String?
    /// Display subscriber count, e.g. "20.8M subscribers".
    let subscriberCountText: String?
    let descriptionSnippet: String?
    let thumbnailURL: URL?

    var id: String {
        self.channelId
    }

    init(
        channelId: String,
        name: String,
        handle: String? = nil,
        subscriberCountText: String? = nil,
        descriptionSnippet: String? = nil,
        thumbnailURL: URL? = nil
    ) {
        self.channelId = channelId
        self.name = name
        self.handle = handle
        self.subscriberCountText = subscriberCountText
        self.descriptionSnippet = descriptionSnippet
        self.thumbnailURL = thumbnailURL
    }
}

// MARK: - YouTubeChannelDetail

/// A channel page: metadata plus the videos visible on the landing tab.
struct YouTubeChannelDetail: Hashable {
    let channel: YouTubeChannel
    let videos: [YouTubeVideo]
}
