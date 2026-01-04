import SwiftUI

// MARK: - NavigationDestinationsModifier

/// View modifier that adds common navigation destinations for Playlist, Artist, MoodCategory, and TopSongsDestination.
/// Note: Lyrics sidebar is handled globally in MainWindow, outside the NavigationSplitView.
@available(macOS 26.0, *)
struct NavigationDestinationsModifier: ViewModifier {
    let client: any YTMusicClientProtocol

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: Playlist.self) { playlist in
                // Check if this is a mood/genre category disguised as a playlist
                if MoodCategory.isMoodCategory(playlist.id) {
                    // Parse the ID and navigate to mood category view
                    if let parsed = MoodCategory.parseId(playlist.id) {
                        let category = MoodCategory(
                            browseId: parsed.browseId,
                            params: parsed.params,
                            title: playlist.title
                        )
                        MoodCategoryDetailView(
                            viewModel: MoodCategoryViewModel(
                                category: category,
                                client: self.client
                            )
                        )
                    } else {
                        // Fallback - shouldn't happen
                        PlaylistDetailView(
                            playlist: playlist,
                            viewModel: PlaylistDetailViewModel(
                                playlist: playlist,
                                client: self.client
                            )
                        )
                    }
                } else {
                    PlaylistDetailView(
                        playlist: playlist,
                        viewModel: PlaylistDetailViewModel(
                            playlist: playlist,
                            client: self.client
                        )
                    )
                }
            }
            .navigationDestination(for: MoodCategory.self) { (category: MoodCategory) in
                MoodCategoryDetailView(
                    viewModel: MoodCategoryViewModel(
                        category: category,
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
            .navigationDestination(for: PodcastShow.self) { show in
                PodcastShowView(show: show, client: self.client)
            }
    }
}

@available(macOS 26.0, *)
extension View {
    /// Adds common navigation destinations for Playlist, Artist, MoodCategory, and TopSongsDestination.
    func navigationDestinations(client: any YTMusicClientProtocol) -> some View {
        modifier(NavigationDestinationsModifier(client: client))
    }
}
