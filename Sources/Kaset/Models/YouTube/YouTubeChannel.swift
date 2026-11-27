import Foundation

struct YouTubeChannel: Identifiable, Hashable {
    let channelId: String
    let name: String
    let handle: String?
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

struct YouTubeChannelDetail: Hashable {
    let channel: YouTubeChannel
    let videos: [YouTubeVideo]
}
