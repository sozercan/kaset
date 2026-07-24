import SwiftUI

/// New Releases view displaying recently released music.
struct NewReleasesView: View {
    @State var viewModel: NewReleasesViewModel
    @Environment(PlayerService.self) private var playerService
    @State private var navigationPath = NavigationPath()
    @State private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        NavigationStack(path: self.$navigationPath) {
            Group {
                if !self.networkMonitor.isConnected {
                    ErrorView(
                        title: String(localized: "No Connection"),
                        message: String(localized: "Please check your internet connection and try again.")
                    ) {
                        Task { await self.viewModel.refresh() }
                    }
                } else {
                    switch self.viewModel.loadingState {
                    case .idle, .loading:
                        LoadingView(String(localized: "Loading new releases..."))
                    case .loaded, .loadingMore:
                        self.contentView
                    case let .error(error):
                        ErrorView(error: error) {
                            Task { await self.viewModel.refresh() }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .localizedNavigationTitle("New Releases")
            .navigationDestinations(
                client: self.viewModel.client,
                playerBarNavigationAction: self.playerBarNavigationAction
            )
            .playerBarMusicNavigation(path: self.$navigationPath)
        }
        .playerBarMusicNavigation(path: self.$navigationPath)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
                .playerBarMusicNavigation(path: self.$navigationPath)
        }
        .onAppear {
            if self.viewModel.loadingState == .idle {
                Task {
                    await self.viewModel.load()
                }
            }
        }
        .refreshable {
            await self.viewModel.refresh()
        }
        .popsNavigationStackOnSidebarReselect(path: self.$navigationPath, for: .newReleases)
    }

    private var playerBarNavigationAction: PlayerBarNavigationAction {
        PlayerBarNavigationAction(
            openArtist: { self.navigationPath.append($0) },
            openAlbum: { self.navigationPath.append($0) }
        )
    }

    // MARK: - Views

    private var contentView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(self.viewModel.sections) { section in
                    self.sectionView(section)
                }

                if self.viewModel.hasMoreSections || self.viewModel.loadingState == .loadingMore {
                    LoadMoreFooter(
                        isLoading: self.viewModel.loadingState == .loadingMore,
                        title: "Load More",
                        loadingTitle: "Loading more...",
                        autoLoad: true,
                        autoLoadTrigger: self.viewModel.sections.count
                    ) {
                        await self.viewModel.loadMore()
                    }
                }
            }
            // Edge-to-edge so shelves slide under the glass sidebar; resting
            // inset is restored per-shelf via contentInset.
            .padding(.vertical, 20)
        }
    }

    private func sectionView(_ section: HomeSection) -> some View {
        CarouselShelfSection(
            accessibilityLabel: section.title,
            items: Array(section.items.enumerated()),
            id: \.element.id,
            itemAlignment: .top,
            contentInset: DetailContentLayout.horizontalInset
        ) {
            Text(section.title)
                .font(.title2)
                .fontWeight(.semibold)
        } itemContent: { index, item in
            HomeSectionItemCard(
                item: item,
                rank: section.isChart ? index + 1 : nil,
                playAction: self.quickPlayAction(for: item)
            ) {
                self.playItem(item, in: section, at: index)
            }
        }
    }

    // MARK: - Actions

    private func quickPlayAction(for item: HomeSectionItem) -> (() -> Void)? {
        switch item {
        case let .playlist(playlist) where SongActionsHelper.canQuickPlayPlaylist(playlist):
            {
                SongActionsHelper.playPlaylist(
                    playlist,
                    client: self.viewModel.client,
                    playerService: self.playerService
                )
            }
        case let .album(album):
            {
                SongActionsHelper.playAlbum(
                    album,
                    client: self.viewModel.client,
                    playerService: self.playerService
                )
            }
        default:
            nil
        }
    }

    private func playItem(_ item: HomeSectionItem, in _: HomeSection, at _: Int) {
        switch item {
        case let .song(song):
            Task {
                await self.playerService.playWithRadio(song: song)
            }
        case let .playlist(playlist):
            self.navigationPath.append(playlist)
        case let .album(album):
            let playlist = Playlist(
                id: album.id,
                title: album.title,
                description: nil,
                thumbnailURL: album.thumbnailURL,
                trackCount: album.trackCount,
                author: Artist.inline(name: album.artistsDisplay, namespace: "album-artist")
            )
            self.navigationPath.append(playlist)
        case let .artist(artist):
            self.navigationPath.append(artist)
        }
    }
}

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    NewReleasesView(viewModel: NewReleasesViewModel(client: client))
        .environment(PlayerService())
        .environment(authService)
}
