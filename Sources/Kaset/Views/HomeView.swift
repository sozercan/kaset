import SwiftUI

// MARK: - HomeView

/// Home view displaying personalized content sections.
struct HomeView: View {
    @State var viewModel: HomeViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(AuthService.self) private var authService
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
                        HomeLoadingView()
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
            .localizedNavigationTitle("Home")
            .navigationDestinations(client: self.viewModel.client)
            .playerBarMusicNavigation(path: self.$navigationPath)
        }
        .playerBarMusicNavigation(path: self.$navigationPath)
        // The window toolbar shows its Home refresh button only on Home's root page.
        .preference(key: MusicHomeAtRootPreferenceKey.self, value: self.navigationPath.isEmpty)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
                .playerBarMusicNavigation(path: self.$navigationPath)
        }
        .onAppear {
            Task {
                if self.viewModel.loadingState == .idle {
                    await self.viewModel.load()
                } else {
                    await self.refreshIfStale()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await self.refreshIfStale() }
        }
        .popsNavigationStackOnSidebarReselect(path: self.$navigationPath, for: .home)
    }

    /// Skips the automatic refresh while offline (for example right after the
    /// Mac wakes), so the loaded content isn't replaced by an error.
    private func refreshIfStale() async {
        guard self.networkMonitor.isConnected else { return }
        await self.viewModel.refreshIfStale()
    }

    // MARK: - Views

    private var contentView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                // Favorites section (hidden when empty)
                if self.authService.hasPersonalAccount, self.favoritesManager.isVisible {
                    FavoritesSection(
                        onNavigate: { destination in
                            if let playlist = destination as? Playlist {
                                self.navigationPath.append(playlist)
                            } else if let artist = destination as? Artist {
                                self.navigationPath.append(artist)
                            } else if let podcastShow = destination as? PodcastShow {
                                self.navigationPath.append(podcastShow)
                            }
                        },
                        contentInset: DetailContentLayout.horizontalInset
                    )
                    .staggeredAppearance(index: 0)
                }

                // API sections
                ForEach(self.viewModel.sections) { section in
                    self.sectionView(section)
                        .task {
                            await self.prefetchImagesAsync(for: section)
                        }
                }

                if self.viewModel.hasMoreSections || self.viewModel.loadingState == .loadingMore {
                    self.loadMoreControl
                }
            }
            // The ScrollView fills the detail column edge-to-edge so shelves
            // scroll under the floating glass sidebar; each shelf restores a
            // resting inset via `contentInset`. Only the vertical inset stays
            // on the stack.
            .padding(.vertical, 20)
        }
        .accessibilityIdentifier(AccessibilityID.Home.scrollView)
        .pullToRefresh {
            await self.viewModel.refresh()
        }
    }

    private var loadMoreControl: some View {
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

    private func sectionView(_ section: HomeSection) -> some View {
        HomeItemShelfSection(
            accessibilityLabel: section.title,
            items: section.items,
            isChart: section.isChart,
            contentInset: DetailContentLayout.horizontalInset,
            action: { item, index in
                self.playItem(item, in: section, at: index)
            },
            playlistPlayAction: { item in
                self.playlistPlayAction(for: item)
            },
            header: {
                Text(section.title)
                    .font(.title2)
                    .fontWeight(.semibold)
            },
            contextMenu: { item, index in
                self.contextMenuItems(for: item, in: section, at: index)
            }
        )
    }

    // MARK: - Context Menu

    private func playlistPlayAction(for item: HomeSectionItem) -> (() -> Void)? {
        guard case let .playlist(playlist) = item,
              SongActionsHelper.canQuickPlayPlaylist(playlist)
        else {
            return nil
        }

        return {
            SongActionsHelper.playPlaylist(
                playlist,
                client: self.viewModel.client,
                playerService: self.playerService
            )
        }
    }

    private func contextMenuItems(for item: HomeSectionItem, in section: HomeSection, at index: Int) -> some View {
        HomeSectionItemContextMenu(
            item: item,
            client: self.viewModel.client,
            play: { self.playItem(item, in: section, at: index) },
            navigate: { self.navigationPath.append($0) }
        )
    }

    // MARK: - Image Prefetching

    private static let thumbnailDisplaySize = CGSize(width: 160, height: 160)

    private func prefetchImagesAsync(for section: HomeSection) async {
        // Early exit if task is cancelled
        guard !Task.isCancelled else { return }

        let urls = section.items.prefix(6).compactMap { $0.thumbnailURL?.highQualityThumbnailURL }
        guard !urls.isEmpty else { return }

        await ImageCache.shared.prefetch(
            urls: urls,
            targetSize: Self.thumbnailDisplaySize,
            maxConcurrent: 2
        )
    }

    // MARK: - Actions

    private func playItem(_ item: HomeSectionItem, in _: HomeSection, at _: Int) {
        switch item {
        case let .song(song):
            // Play the song and fetch similar songs (radio queue) in the background
            Task {
                await self.playerService.playWithRadio(song: song)
            }
        case let .playlist(playlist):
            // Navigate to playlist detail
            self.navigationPath.append(playlist)
        case let .album(album):
            // For now, we'll create a playlist-like navigation for albums
            // In a full implementation, we'd have an AlbumDetailView
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
            // Navigate to artist detail
            self.navigationPath.append(artist)
        }
    }
}

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    HomeView(viewModel: HomeViewModel(client: client))
        .environment(PlayerService())
        .environment(authService)
        .environment(FavoritesManager.shared)
}

// MARK: - MusicHomeAtRootPreferenceKey

/// Whether Music Home is visible on its root page (no album, playlist, or
/// artist pushed), so `MainWindow` can show its toolbar refresh button.
struct MusicHomeAtRootPreferenceKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
