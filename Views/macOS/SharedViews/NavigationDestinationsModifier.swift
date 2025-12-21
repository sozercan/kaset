import SwiftUI

// MARK: - NavigationDestinationsModifier

/// View modifier that adds common navigation destinations for Playlist, Artist, and TopSongsDestination.
/// Note: Lyrics sidebar is handled globally in MainWindow, outside the NavigationSplitView.
@available(macOS 26.0, *)
struct NavigationDestinationsModifier: ViewModifier {
    let client: any YTMusicClientProtocol

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(
                    playlist: playlist,
                    viewModel: PlaylistDetailViewModel(
                        playlist: playlist,
                        client: self.client
                    )
                )
            }
            .navigationDestination(for: Artist.self) { artist in
                ArtistDetailView(
                    artist: artist,
                    viewModel: ArtistDetailViewModel(
                        artist: artist,
                        client: self.client
                    )
                )
            }
            .navigationDestination(for: TopSongsDestination.self) { destination in
                TopSongsView(viewModel: TopSongsViewModel(
                    destination: destination,
                    client: self.client
                ))
            }
    }
}

@available(macOS 26.0, *)
extension View {
    /// Adds common navigation destinations for Playlist, Artist, and TopSongsDestination.
    func navigationDestinations(client: any YTMusicClientProtocol) -> some View {
        modifier(NavigationDestinationsModifier(client: client))
    }
}
