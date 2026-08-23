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
            // Pushed views don't inherit safeAreaInsets, so every
            // destination carries its own player bar (music-side rule).
            Group {
                switch route {
                case let .watch(video):
                    YouTubeWatchView(video: video, client: client)
                case let .channel(channelId):
                    YouTubeChannelView(channelId: channelId, client: client)
                case let .playlist(playlistId):
                    YouTubePlaylistDetailView(playlistId: playlistId, client: client)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .youtubePlayerBarInset()
        }
    }
}
