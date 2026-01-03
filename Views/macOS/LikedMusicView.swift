import SwiftUI

/// View displaying the user's liked songs.
@available(macOS 26.0, *)
struct LikedMusicView: View {
    @State var viewModel: LikedMusicViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(SongLikeStatusManager.self) private var likeStatusManager
    @State private var networkMonitor = NetworkMonitor.shared

    @State private var navigationPath = NavigationPath()

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
                        LoadingView("Loading liked songs...")
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
            .navigationTitle("Liked Music")
            .navigationDestination(for: Artist.self) { artist in
                ArtistDetailView(
                    artist: artist,
                    viewModel: ArtistDetailViewModel(
                        artist: artist,
                        client: self.viewModel.client
                    )
                )
            }
            .navigationDestination(for: TopSongsDestination.self) { destination in
                TopSongsView(
                    viewModel: TopSongsViewModel(
                        destination: destination,
                        client: self.viewModel.client
                    ))
            }
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(
                    playlist: playlist,
                    viewModel: PlaylistDetailViewModel(
                        playlist: playlist,
                        client: self.viewModel.client
                    )
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
        }
        .task {
            if self.viewModel.loadingState == .idle {
                await self.viewModel.load()
            }
        }
        .refreshable {
            await self.viewModel.refresh()
        }
    }

    // MARK: - Views

    private var contentView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Header with play all button
                self.headerView
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)

                // Songs list
                if self.viewModel.songs.isEmpty {
                    self.emptyStateView
                } else {
                    ForEach(self.viewModel.songs.indices, id: \.self) { index in
                        let song = self.viewModel.songs[index]
                        self.songRow(song, index: index)
                            .onAppear {
                                // Load more when reaching the last few items
                                if index >= self.viewModel.songs.count - 3, self.viewModel.hasMore {
                                    Task { await self.viewModel.loadMore() }
                                }
                            }
                        if index < self.viewModel.songs.count - 1 {
                            Divider()
                                .padding(.leading, 72)
                        }
                    }

                    // Loading indicator for pagination
                    if self.viewModel.loadingState == .loadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                                .padding()
                            Spacer()
                        }
                    }
                }
            }
            .padding(.vertical, 20)
        }
    }

    private var headerView: some View {
        HStack(spacing: 16) {
            // Liked music icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [.red, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)

                Image(systemName: "heart.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Liked Music")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("\(self.viewModel.songs.count) songs")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Play all button
            if !self.viewModel.songs.isEmpty {
                Button {
                    Task {
                        await self.playerService.playQueue(self.viewModel.songs, startingAt: 0)
                    }
                } label: {
                    Label("Play All", systemImage: "play.fill")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // Shuffle button
                Button {
                    Task {
                        let shuffled = self.viewModel.songs.shuffled()
                        await self.playerService.playQueue(shuffled, startingAt: 0)
                    }
                } label: {
                    Image(systemName: "shuffle")
                        .font(.headline)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No liked songs yet")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Songs you like will appear here")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func songRow(_ song: Song, index: Int) -> some View {
        Button {
            Task {
                await self.playerService.playQueue(self.viewModel.songs, startingAt: index)
            }
        } label: {
            HStack(spacing: 12) {
                // Thumbnail
                CachedAsyncImage(url: song.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "music.note")
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 48, height: 48)
                .clipShape(.rect(cornerRadius: 6))

                // Song info
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.system(size: 14))
                        .lineLimit(1)

                    Text(song.artistsDisplay)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Duration
                Text(song.durationDisplay)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                // Play indicator
                Image(systemName: "play.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await self.playerService.play(song: song) }
            } label: {
                Label("Play", systemImage: "play.fill")
            }

            Divider()

            FavoritesContextMenu.menuItem(for: song, manager: self.favoritesManager)

            Divider()

            Button {
                SongActionsHelper.unlikeSong(song, likeStatusManager: self.likeStatusManager)
            } label: {
                Label("Unlike", systemImage: "hand.thumbsup.fill")
            }

            Divider()

            StartRadioContextMenu.menuItem(for: song, playerService: self.playerService)

            Divider()

            ShareContextMenu.menuItem(for: song)

            Divider()

            // Go to Artist - show first artist with valid ID
            if let artist = song.artists.first(where: { $0.hasNavigableId }) {
                NavigationLink(value: artist) {
                    Label("Go to Artist", systemImage: "person")
                }
            }

            // Go to Album - show if album has valid browse ID
            if let album = song.album, album.hasNavigableId {
                let playlist = Playlist(
                    id: album.id,
                    title: album.title,
                    description: nil,
                    thumbnailURL: album.thumbnailURL ?? song.thumbnailURL,
                    trackCount: album.trackCount,
                    author: album.artistsDisplay
                )
                NavigationLink(value: playlist) {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }
        }
    }
}

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    LikedMusicView(viewModel: LikedMusicViewModel(client: client))
        .environment(PlayerService())
        .environment(FavoritesManager.shared)
}
