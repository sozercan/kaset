import SwiftUI

/// Detail view for a playlist showing its tracks.
@available(macOS 26.0, *)
struct PlaylistDetailView: View {
    let playlist: Playlist
    @State var viewModel: PlaylistDetailViewModel
    @Environment(PlayerService.self) private var playerService

    /// Tracks whether this playlist has been added to library in this session.
    @State private var isAddedToLibrary: Bool = false

    /// Computed property to check if playlist is in library.
    private var isInLibrary: Bool {
        LibraryViewModel.shared?.isInLibrary(playlistId: self.playlist.id) ?? false
    }

    init(playlist: Playlist, viewModel: PlaylistDetailViewModel) {
        self.playlist = playlist
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView("Loading playlist...")
            case .loaded, .loadingMore:
                if let detail = viewModel.playlistDetail {
                    self.contentView(detail)
                } else {
                    ErrorView(title: "Unable to load playlist", message: "Playlist not found") {
                        Task { await self.viewModel.load() }
                    }
                }
            case let .error(message):
                ErrorView(title: "Unable to load playlist", message: message) {
                    Task { await self.viewModel.load() }
                }
            }
        }
        .accentBackground(from: self.viewModel.playlistDetail?.thumbnailURL?.highQualityThumbnailURL)
        .navigationTitle(self.playlist.title)
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
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

    private func contentView(_ detail: PlaylistDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                self.headerView(detail)

                Divider()

                // Tracks
                self.tracksView(detail.tracks, isAlbum: detail.isAlbum)
            }
            .padding(24)
        }
    }

    private func headerView(_ detail: PlaylistDetail) -> some View {
        HStack(alignment: .top, spacing: 20) {
            // Thumbnail
            CachedAsyncImage(url: detail.thumbnailURL?.highQualityThumbnailURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 180, height: 180)
            .clipShape(.rect(cornerRadius: 8))
            .fadeIn(duration: 0.3)

            // Info
            VStack(alignment: .leading, spacing: 8) {
                Text(detail.isAlbum ? "Album" : "Playlist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text(detail.title)
                    .font(.title)
                    .fontWeight(.bold)

                if let author = detail.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 16) {
                    // Play all button
                    Button {
                        self.playAll(detail.tracks)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(detail.tracks.isEmpty)

                    // Add/Remove Library button
                    let currentlyInLibrary = self.isInLibrary || self.isAddedToLibrary
                    Button {
                        self.toggleLibrary()
                    } label: {
                        Label(
                            currentlyInLibrary ? "Added to Library" : "Add to Library",
                            systemImage: currentlyInLibrary ? "checkmark.circle.fill" : "plus.circle"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    // Track count
                    Text("\(detail.tracks.count) songs")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let duration = detail.duration {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(duration)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tracksView(_ tracks: [Song], isAlbum: Bool) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                self.trackRow(track, index: index, tracks: tracks, isAlbum: isAlbum)

                if index < tracks.count - 1 {
                    Divider()
                        // For albums: 28 (index) + 12 (spacing)
                        // For playlists: 28 (index) + 12 (spacing) + 40 (thumbnail) + 16 (spacing)
                        .padding(.leading, isAlbum ? 40 : 96)
                }
            }
        }
    }

    private func trackRow(_ track: Song, index: Int, tracks: [Song], isAlbum: Bool) -> some View {
        Button {
            self.playTrackInQueue(tracks: tracks, startingAt: index)
        } label: {
            HStack(spacing: 12) {
                // Now playing indicator or index
                Group {
                    if self.playerService.currentTrack?.videoId == track.videoId {
                        NowPlayingIndicator(isPlaying: self.playerService.isPlaying, size: 14)
                    } else {
                        Text("\(index + 1)")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 28, alignment: .trailing)

                // Thumbnail - only show for playlists (different album art per track)
                // Albums share the same artwork, so we hide per-track thumbnails
                if !isAlbum {
                    CachedAsyncImage(url: track.thumbnailURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle()
                            .fill(.quaternary)
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(.rect(cornerRadius: 4))
                }

                // Title and artist
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14))
                        .foregroundStyle(self.playerService.currentTrack?.videoId == track.videoId ? .red : .primary)
                        .lineLimit(1)

                    Text(track.artistsDisplay)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Duration
                Text(track.durationDisplay)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 45, alignment: .trailing)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.interactiveRow(cornerRadius: 6))
        .staggeredAppearance(index: min(index, 10))
        .contextMenu {
            Button {
                self.playTrackInQueue(tracks: tracks, startingAt: index)
            } label: {
                Label("Play", systemImage: "play.fill")
            }

            Divider()

            Button {
                SongActionsHelper.likeSong(track, playerService: self.playerService)
            } label: {
                Label("Like", systemImage: "hand.thumbsup")
            }

            Button {
                SongActionsHelper.dislikeSong(track, playerService: self.playerService)
            } label: {
                Label("Dislike", systemImage: "hand.thumbsdown")
            }

            Divider()

            Button {
                SongActionsHelper.addToLibrary(track, playerService: self.playerService)
            } label: {
                Label("Add to Library", systemImage: "plus.circle")
            }
        }
    }

    // MARK: - Actions

    private func playTrackInQueue(tracks: [Song], startingAt index: Int) {
        Task {
            await self.playerService.playQueue(tracks, startingAt: index)
        }
    }

    private func playAll(_ tracks: [Song]) {
        guard !tracks.isEmpty else { return }
        Task {
            await self.playerService.playQueue(tracks, startingAt: 0)
        }
    }

    private func toggleLibrary() {
        let currentlyInLibrary = self.isInLibrary || self.isAddedToLibrary
        Task {
            if currentlyInLibrary {
                await SongActionsHelper.removePlaylistFromLibrary(self.playlist, client: self.viewModel.client)
                self.isAddedToLibrary = false
            } else {
                await SongActionsHelper.addPlaylistToLibrary(self.playlist, client: self.viewModel.client)
                self.isAddedToLibrary = true
            }
        }
    }
}

#Preview {
    let playlist = Playlist(
        id: "test",
        title: "Test Playlist",
        description: nil,
        thumbnailURL: nil,
        trackCount: 10,
        author: "Test Author"
    )
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    PlaylistDetailView(
        playlist: playlist,
        viewModel: PlaylistDetailViewModel(
            playlist: playlist,
            client: client
        )
    )
    .environment(PlayerService())
}
