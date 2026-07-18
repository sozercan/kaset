import SwiftUI

// MARK: - NavigationDestinationsModifier

/// View modifier that adds common navigation destinations for Playlist, Artist, MoodCategory, and TopSongsDestination.
/// Note: Lyrics sidebar is handled globally in MainWindow, outside the NavigationSplitView.
struct NavigationDestinationsModifier: ViewModifier {
    let client: any YTMusicClientProtocol
    let playerBarNavigationAction: PlayerBarNavigationAction
    @Environment(LibraryViewModel.self) private var libraryViewModel: LibraryViewModel?
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI

    // swiftlint:disable:next function_body_length
    func body(content: Content) -> some View {
        content
            .navigationDestination(for: Playlist.self) { playlist in
                // Check if this is a mood/genre category disguised as a playlist
                if playlist.resolvedMoodCategoryEndpoint != nil {
                    if let parsed = playlist.resolvedMoodCategoryEndpoint {
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
                        if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
                            PlaylistDetailView(
                                playlist: playlist,
                                viewModel: PlaylistDetailViewModel(
                                    playlist: playlist,
                                    client: self.client
                                ),
                                playerBarNavigationAction: self.playerBarNavigationAction
                            )
                        } else {
                            SimplePlaylistDetailView(
                                playlist: playlist,
                                viewModel: PlaylistDetailViewModel(
                                    playlist: playlist,
                                    client: self.client
                                ),
                                playerBarNavigationAction: self.playerBarNavigationAction
                            )
                        }
                    }
                } else {
                    if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
                        PlaylistDetailView(
                            playlist: playlist,
                            viewModel: PlaylistDetailViewModel(
                                playlist: playlist,
                                client: self.client
                            ),
                            playerBarNavigationAction: self.playerBarNavigationAction
                        )
                    } else {
                        SimplePlaylistDetailView(
                            playlist: playlist,
                            viewModel: PlaylistDetailViewModel(
                                playlist: playlist,
                                client: self.client
                            ),
                            playerBarNavigationAction: self.playerBarNavigationAction
                        )
                    }
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
                        client: self.client,
                        libraryViewModel: self.libraryViewModel
                    ),
                    playerBarNavigationAction: self.playerBarNavigationAction
                )
            }
            .navigationDestination(for: TopSongsDestination.self) { destination in
                TopSongsView(viewModel: TopSongsViewModel(
                    destination: destination,
                    client: self.client
                ))
            }
            .navigationDestination(for: PodcastShow.self) { [libraryViewModel] show in
                PodcastShowView(show: show, client: self.client)
                    .environment(libraryViewModel)
            }
            .navigationDestination(for: ArtistSeeAllDestination.self) { destination in
                switch destination.endpoint.pageType {
                case .discography:
                    ArtistDiscographyView(viewModel: ArtistDiscographyViewModel(
                        destination: destination,
                        client: self.client
                    ))
                case .artist:
                    ArtistEpisodesListView(viewModel: ArtistEpisodesListViewModel(
                        destination: destination,
                        client: self.client
                    ))
                case .playlist:
                    // Playlist destinations route through the `Playlist` value
                    // instead of `ArtistSeeAllDestination`, so this branch is
                    // structurally unreachable. Fall back gracefully.
                    EmptyView()
                }
            }
    }
}

extension View {
    /// Adds common navigation destinations for Playlist, Artist, MoodCategory, and TopSongsDestination.
    func navigationDestinations(
        client: any YTMusicClientProtocol,
        playerBarNavigationAction: PlayerBarNavigationAction = .disabled
    ) -> some View {
        modifier(NavigationDestinationsModifier(
            client: client,
            playerBarNavigationAction: playerBarNavigationAction
        ))
    }
}
