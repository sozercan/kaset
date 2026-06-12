import SwiftUI

// MARK: - YouTubeRoute

/// Navigation routes within the YouTube experience.
enum YouTubeRoute: Hashable {
    case watch(YouTubeVideo)
    case channel(channelId: String)
    case playlist(playlistId: String)
}

// MARK: - Navigation Destinations

extension View {
    /// Registers navigation destinations for YouTube routes
    /// (parallel to the music side's `navigationDestinations(client:)`).
    func youtubeNavigationDestinations(client: any YouTubeClientProtocol) -> some View {
        navigationDestination(for: YouTubeRoute.self) { route in
            switch route {
            case let .watch(video):
                YouTubeWatchView(video: video, client: client)
            case let .channel(channelId):
                YouTubeChannelView(channelId: channelId, client: client)
            case let .playlist(playlistId):
                YouTubePlaylistDetailView(playlistId: playlistId, client: client)
            }
        }
    }
}
