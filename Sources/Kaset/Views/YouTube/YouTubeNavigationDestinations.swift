import SwiftUI

enum YouTubeRoute: Hashable {
    case watch(YouTubeVideo)
    case channel(channelId: String)
    case playlist(playlistId: String)
}

extension View {
    func youtubeNavigationDestinations(client: any YouTubeClientProtocol) -> some View {
        navigationDestination(for: YouTubeRoute.self) { route in
            switch route {
            case let .watch(video):
                YouTubeWatchView(video: video, client: client)
            case let .channel(channelId):
                YouTubeChannelView(channelId: channelId, client: client)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .youtubePagePlayerBarInset()
            case let .playlist(playlistId):
                YouTubePlaylistDetailView(playlistId: playlistId, client: client)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .youtubePagePlayerBarInset()
            }
        }
    }
}
