import SwiftUI

/// Explore view displaying new releases, charts, and moods & genres.
@available(macOS 26.0, *)
struct ExploreView: View {
    @State var viewModel: ExploreViewModel
    @Environment(PlayerService.self) private var playerService
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: self.$navigationPath) {
            Group {
                switch self.viewModel.loadingState {
                case .idle, .loading:
                    LoadingView("Loading explore content...")
                case .loaded, .loadingMore:
                    self.contentView
                case let .error(message):
                    ErrorView(message: message) {
                        Task { await self.viewModel.refresh() }
                    }
                }
            }
            .navigationTitle("Explore")
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

    private func sectionView(_ section: HomeSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.title2)
                .fontWeight(.semibold)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    if section.isChart {
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                            HomeSectionItemCard(item: item, rank: index + 1) {
                                self.playItem(item)
                            }
                        }
                    } else {
                        ForEach(section.items) { item in
                            HomeSectionItemCard(item: item) {
                                self.playItem(item)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func playItem(_ item: HomeSectionItem) {
        switch item {
        case let .song(song):
            Task {
                await self.playerService.play(videoId: song.videoId)
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
    ExploreView(viewModel: ExploreViewModel(client: client))
        .environment(PlayerService())
}
