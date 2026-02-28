import SwiftUI

/// Moods & Genres view for browsing music by mood or genre.
@available(macOS 26.0, *)
struct MoodsAndGenresView: View {
    @State var viewModel: MoodsAndGenresViewModel
    @Environment(PlayerService.self) private var playerService
    @State private var navigationPath = NavigationPath()
    @State private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        NavigationStack(path: self.$navigationPath) {
            Group {
                if !self.networkMonitor.isConnected {
                    ErrorView(
                        title: "No Connection",
                        message: "Please check your internet connection and try again."
                    ) {
                        Task { await self.viewModel.refresh() }
                    }
                } else {
                    switch self.viewModel.loadingState {
                    case .idle, .loading:
                        LoadingView("Loading moods & genres...")
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
            .navigationTitle("Moods & Genres")
            .navigationDestinations(client: self.viewModel.client)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
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
    }

    // MARK: - Views

    private var contentView: some View {
        Group {
            if self.viewModel.sections.isEmpty {
                ContentUnavailableView(
                    "No Moods & Genres Available",
                    systemImage: "guitars",
                    description: Text("Content may not be available in your region.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 32) {
                        ForEach(self.viewModel.sections) { section in
                            self.sectionView(section)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
            }
        }
    }

    private func sectionView(_ section: HomeSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.title2)
                .fontWeight(.semibold)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                        HomeSectionItemCard(item: item) {
                            self.playItem(item, in: section, at: index)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

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
                author: album.artistsDisplay
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
    MoodsAndGenresView(viewModel: MoodsAndGenresViewModel(client: client))
        .environment(PlayerService())
}
