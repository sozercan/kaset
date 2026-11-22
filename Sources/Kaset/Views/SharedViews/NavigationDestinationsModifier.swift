import SwiftUI

struct NavigationDestinationsModifier: ViewModifier {
    let client: any YTMusicClientProtocol
    @Environment(\.libraryViewModel) private var libraryViewModel: LibraryViewModel?
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI

    // swiftlint:disable:next function_body_length
    func body(content: Content) -> some View {
        content
            .navigationDestination(for: Playlist.self) { playlist in
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
                        .environment(\.libraryViewModel, self.libraryViewModel)
                    } else {
                        if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
                            PlaylistDetailView(
                                playlist: playlist,
                                viewModel: PlaylistDetailViewModel(
                                    playlist: playlist,
                                    client: self.client
                                )
                            )
                            .environment(\.libraryViewModel, self.libraryViewModel)
                        } else {
                            SimplePlaylistDetailView(
                                playlist: playlist,
                                viewModel: PlaylistDetailViewModel(
                                    playlist: playlist,
                                    client: self.client
                                )
                            )
                            .environment(\.libraryViewModel, self.libraryViewModel)
                        }
                    }
                } else {
                    if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
                        PlaylistDetailView(
                            playlist: playlist,
                            viewModel: PlaylistDetailViewModel(
                                playlist: playlist,
                                client: self.client
                            )
                        )
                        .environment(\.libraryViewModel, self.libraryViewModel)
                    } else {
                        SimplePlaylistDetailView(
                            playlist: playlist,
                            viewModel: PlaylistDetailViewModel(
                                playlist: playlist,
                                client: self.client
                            )
                        )
                        .environment(\.libraryViewModel, self.libraryViewModel)
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
                .environment(\.libraryViewModel, self.libraryViewModel)
            }
            .navigationDestination(for: Artist.self) { artist in
                ArtistDetailView(
                    artist: artist,
                    viewModel: ArtistDetailViewModel(
                        artist: artist,
                        client: self.client,
                        libraryViewModel: self.libraryViewModel
                    )
                )
                .environment(\.libraryViewModel, self.libraryViewModel)
            }
            .navigationDestination(for: TopSongsDestination.self) { destination in
                TopSongsView(viewModel: TopSongsViewModel(
                    destination: destination,
                    client: self.client
                ))
            }
            .navigationDestination(for: PodcastShow.self) { [libraryViewModel] show in
                PodcastShowView(show: show, client: self.client)
                    .environment(\.libraryViewModel, libraryViewModel)
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
                    EmptyView()
                }
            }
    }
}

extension View {
    func navigationDestinations(client: any YTMusicClientProtocol) -> some View {
        modifier(NavigationDestinationsModifier(client: client))
    }
}
