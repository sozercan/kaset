import Foundation

struct ArtistEpisode: Identifiable, Hashable {
    let id: String
    let videoId: String
    let title: String
    let subtitle: String?
    let description: String?
    let thumbnailURL: URL?
    let isLive: Bool

    init(
        videoId: String,
        title: String,
        subtitle: String? = nil,
        description: String? = nil,
        thumbnailURL: URL? = nil,
        isLive: Bool = false
    ) {
        self.id = videoId
        self.videoId = videoId
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.thumbnailURL = thumbnailURL
        self.isLive = isLive
    }
}
