import Foundation

struct YouTubePlaylist: Identifiable, Hashable {
    let playlistId: String
    let title: String
    let channelName: String?
    let videoCountText: String?
    let thumbnailURL: URL?
    let firstVideoId: String?

    var id: String {
        self.playlistId
    }

    init(
        playlistId: String,
        title: String,
        channelName: String? = nil,
        videoCountText: String? = nil,
        thumbnailURL: URL? = nil,
        firstVideoId: String? = nil
    ) {
        self.playlistId = playlistId
        self.title = title
        self.channelName = channelName
        self.videoCountText = videoCountText
        self.thumbnailURL = thumbnailURL
        self.firstVideoId = firstVideoId
    }
}

struct YouTubePlaylistDetail: Hashable {
    let playlist: YouTubePlaylist
    let videos: [YouTubeVideo]
}
