import SwiftUI

/// Library view displaying user's playlists.
@available(macOS 26.0, *)
struct LibraryView: View {
    @State var viewModel: LibraryViewModel
    @Environment(PlayerService.self) private var playerService

    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                switch viewModel.loadingState {
                case .idle, .loading:
                    LoadingView("Loading your library...")
                case .loaded, .loadingMore:
                    contentView
                case let .error(message):
                    ErrorView(title: "Unable to load library", message: message) {
                        Task { await viewModel.refresh() }
                    }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(
                    playlist: playlist,
                    viewModel: PlaylistDetailViewModel(
                        playlist: playlist,
                        client: viewModel.client
                    )
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
        }
        .task {
            if viewModel.loadingState == .idle {
                await viewModel.load()
            }
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    // MARK: - Views

    private var contentView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                // Playlists section
                playlistsSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Playlists")
                .font(.title2)
                .fontWeight(.semibold)

            if viewModel.playlists.isEmpty {
                emptyPlaylistsView
            } else {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16),
                ], spacing: 16) {
                    ForEach(viewModel.playlists) { playlist in
                        playlistCard(playlist)
                    }
                }
            }
        }
    }

    private var emptyPlaylistsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text("No playlists yet")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Create playlists on YouTube Music to see them here.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    private func playlistCard(_ playlist: Playlist) -> some View {
        Button {
            navigationPath.append(playlist)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail
                CachedAsyncImage(url: playlist.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "music.note.list")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 160, height: 160)
                .clipShape(.rect(cornerRadius: 8))

                // Title
                Text(playlist.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 160, alignment: .leading)

                // Track count
                if let count = playlist.trackCount {
                    Text("\(count) songs")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    LibraryView(viewModel: LibraryViewModel(client: client))
        .environment(PlayerService())
}
