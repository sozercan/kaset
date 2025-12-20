import SwiftUI

/// Home view displaying personalized content sections.
struct HomeView: View {
    @State var viewModel: HomeViewModel
    @Environment(PlayerService.self) private var playerService
    @State private var navigationPath = NavigationPath()
    @State private var selectedPlaylist: Playlist?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                switch viewModel.loadingState {
                case .idle, .loading:
                    loadingView
                case .loaded:
                    contentView
                case let .error(message):
                    errorView(message: message)
                }
            }
            .navigationTitle("Home")
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

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading your music...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var contentView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(viewModel.sections) { section in
                    sectionView(section)
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
                    ForEach(section.items) { item in
                        itemCard(item)
                    }
                }
            }
        }
    }

    private func itemCard(_ item: HomeSectionItem) -> some View {
        Button {
            playItem(item)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail
                AsyncImage(url: item.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 160, height: 160)
                .clipShape(.rect(cornerRadius: 8))

                // Title
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 160, alignment: .leading)

                // Subtitle
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 160, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text("Unable to load content")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                Task {
                    await viewModel.refresh()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func playItem(_ item: HomeSectionItem) {
        switch item {
        case let .song(song):
            // Play the song directly
            Task {
                await playerService.play(videoId: song.videoId)
            }
        case let .playlist(playlist):
            // Navigate to playlist detail
            navigationPath.append(playlist)
        case let .album(album):
            // For now, we'll create a playlist-like navigation for albums
            // In a full implementation, we'd have an AlbumDetailView
            let playlist = Playlist(
                id: album.id,
                title: album.title,
                description: nil,
                thumbnailURL: album.thumbnailURL,
                trackCount: album.trackCount,
                author: album.artistsDisplay
            )
            navigationPath.append(playlist)
        case .artist:
            // Artist navigation not implemented in MVP
            break
        }
    }
}

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    HomeView(viewModel: HomeViewModel(client: client))
        .environment(PlayerService())
}
