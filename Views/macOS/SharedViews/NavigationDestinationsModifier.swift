import SwiftUI

// MARK: - NavigationDestinationsModifier

/// View modifier that adds common navigation destinations for Playlist, Artist, and TopSongsDestination.
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
                        client: client
                    )
                )
            }
            .navigationDestination(for: Artist.self) { artist in
                ArtistDetailView(
                    artist: artist,
                    viewModel: ArtistDetailViewModel(
                        artist: artist,
                        client: client
                    )
                )
            }
            .navigationDestination(for: TopSongsDestination.self) { destination in
                TopSongsView(viewModel: TopSongsViewModel(
                    destination: destination,
                    client: client
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
