import SwiftUI

/// View displaying all top songs for an artist.
@available(macOS 26.0, *)
struct TopSongsView: View {
    @State var viewModel: TopSongsViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(SongLikeStatusManager.self) private var likeStatusManager

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                if self.viewModel.songs.isEmpty {
                    LoadingView("Loading songs...")
                } else {
                    // Show existing songs while loading more
                    self.songsListView
                        .overlay(alignment: .top) {
                            if self.viewModel.loadingState == .loading {
                                ProgressView()
                                    .controlSize(.regular)
                                    .frame(width: 20, height: 20)
                                    .padding()
                            }
                        }
                }
            case .loaded, .loadingMore:
                self.songsListView
            case let .error(error):
                ErrorView(error: error) {
                    Task {
                        await self.viewModel.load()
                    }
                }
            }
        }
        .navigationTitle("Top songs")
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .error = self.viewModel.loadingState {} else {
                PlayerBar()
            }
        }
        .task {
            if self.viewModel.loadingState == .idle {
                await self.viewModel.load()
            }
        }
    }

    // MARK: - Views

    private var songsListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(self.viewModel.songs.enumerated()), id: \.element.id) { index, song in
                    self.songRow(song, index: index)

                    if index < self.viewModel.songs.count - 1 {
                        Divider()
                            .padding(.leading, 56)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Song Row

    private func songRow(_ song: Song, index: Int) -> some View {
        Button {
            self.playSongInQueue(startingAt: index)
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
                }
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: 4))

                // Title
                Text(song.title)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Artist column
                Text(song.artistsDisplay)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)

                // Album column (if available)
                if let album = song.album {
                    Text(album.title)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 180, alignment: .leading)
                } else {
                    Spacer()
                        .frame(width: 180)
                }

                // Duration
                Text(song.durationDisplay)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                self.playSongInQueue(startingAt: index)
            } label: {
                Label("Play", systemImage: "play.fill")
            }

            Divider()

            FavoritesContextMenu.menuItem(for: song, manager: self.favoritesManager)

            Divider()

            LikeDislikeContextMenu(song: song, likeStatusManager: self.likeStatusManager)

            Divider()

            StartRadioContextMenu.menuItem(for: song, playerService: self.playerService)

            Divider()

            Button {
                SongActionsHelper.addToLibrary(song, playerService: self.playerService)
            } label: {
                Label("Add to Library", systemImage: "plus.circle")
            }

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

    // MARK: - Actions

    private func playSongInQueue(startingAt index: Int) {
        Task {
            await self.playerService.playQueue(self.viewModel.songs, startingAt: index)
        }
    }
}

#Preview {
    let songs = (1 ... 10).map { i in
        Song(
            id: "song\(i)",
            title: "Song \(i)",
            artists: [Artist(id: "artist1", name: "Test Artist")],
            album: Album(id: "album1", title: "Test Album", artists: nil, thumbnailURL: nil, year: "2023", trackCount: 10),
            duration: TimeInterval(180 + i * 30),
            thumbnailURL: nil,
            videoId: "video\(i)"
        )
    }
    let destination = TopSongsDestination(
        artistId: "artist1",
        artistName: "Test Artist",
        songs: songs,
        songsBrowseId: nil,
        songsParams: nil
    )
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    TopSongsView(viewModel: TopSongsViewModel(destination: destination, client: client))
        .environment(PlayerService())
        .environment(FavoritesManager.shared)
}
