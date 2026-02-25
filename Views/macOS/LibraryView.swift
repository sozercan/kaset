import SwiftUI

// MARK: - LibraryFilter

/// Filter options for the Library view.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case playlists = "Playlists"
    case artists = "Artists"
    case podcasts = "Podcasts"

    var id: String {
        self.rawValue
    }

    var icon: String {
        switch self {
        case .all: "square.grid.2x2"
        case .playlists: "music.note.list"
        case .artists: "music.microphone"
        case .podcasts: "mic.fill"
        }
    }
}

// MARK: - LibraryView

/// Library view displaying user's playlists and podcast shows.
@available(macOS 26.0, *)
struct LibraryView: View {
    @State var viewModel: LibraryViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(LibraryViewModel.self) private var libraryViewModelEnv: LibraryViewModel?
    @State private var networkMonitor = NetworkMonitor.shared

    @State private var navigationPath = NavigationPath()
    @State private var selectedFilter: LibraryFilter = .all

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
                        LoadingView("Loading your library...")
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
            .navigationTitle("Library")
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(
                    playlist: playlist,
                    viewModel: PlaylistDetailViewModel(
                        playlist: playlist,
                        client: self.viewModel.client
                    )
                )
            }
            .navigationDestination(for: Artist.self) { artist in
                ArtistDetailView(
                    artist: artist,
                    viewModel: ArtistDetailViewModel(
                        artist: artist,
                        client: self.viewModel.client
                    )
                )
            }
            .navigationDestination(for: PodcastShow.self) { [libraryViewModelEnv] show in
                PodcastShowView(show: show, client: self.viewModel.client)
                    .environment(libraryViewModelEnv)
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
            LazyVStack(alignment: .leading, spacing: 20) {
                // Filter chips
                self.filterChips

                // Combined grid with filtered content
                self.libraryGrid
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(LibraryFilter.allCases) { filter in
                self.filterChip(filter)
            }
            Spacer()
        }
    }

    private func filterChip(_ filter: LibraryFilter) -> some View {
        let isSelected = self.selectedFilter == filter

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                self.selectedFilter = filter
            }
        } label: {
            Text(filter.rawValue)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background {
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                }
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    /// All library items combined and filtered.
    private var filteredItems: [LibraryItem] {
        var items: [LibraryItem] = []

        switch self.selectedFilter {
        case .all:
            // Interleave playlists, artists, and podcasts for variety
            items = self.viewModel.playlists.map { .playlist($0) }
                + self.viewModel.artists.map { .artist($0) }
                + self.viewModel.podcastShows.map { .podcast($0) }
        case .playlists:
            items = self.viewModel.playlists.map { .playlist($0) }
        case .artists:
            items = self.viewModel.artists.map { .artist($0) }
        case .podcasts:
            items = self.viewModel.podcastShows.map { .podcast($0) }
        }

        return items
    }

    private var libraryGrid: some View {
        Group {
            if self.filteredItems.isEmpty {
                self.emptyStateView
            } else {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16),
                ], spacing: 16) {
                    ForEach(self.filteredItems) { item in
                        switch item {
                        case let .playlist(playlist):
                            self.playlistCard(playlist)
                        case let .artist(artist):
                            self.artistCard(artist)
                        case let .podcast(show):
                            self.podcastCard(show)
                        }
                    }
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: self.selectedFilter.icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text(self.emptyStateTitle)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(self.emptyStateMessage)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    private var emptyStateTitle: String {
        switch self.selectedFilter {
        case .all:
            "Your library is empty"
        case .playlists:
            "No playlists yet"
        case .artists:
            "No artists yet"
        case .podcasts:
            "No podcasts yet"
        }
    }

    private var emptyStateMessage: String {
        switch self.selectedFilter {
        case .all:
            "Save playlists, follow artists, and subscribe to podcasts on YouTube Music to see them here."
        case .playlists:
            "Create or save playlists on YouTube Music to see them here."
        case .artists:
            "Follow artists on YouTube Music to see them here."
        case .podcasts:
            "Subscribe to podcasts on YouTube Music to see them here."
        }
    }

    private func playlistCard(_ playlist: Playlist) -> some View {
        Button {
            self.navigationPath.append(playlist)
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

    private func artistCard(_ artist: Artist) -> some View {
        Button {
            self.navigationPath.append(artist)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail (circular for artists)
                CachedAsyncImage(url: artist.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "music.microphone")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 160, height: 160)
                .clipShape(.circle)

                // Name
                Text(artist.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 160, alignment: .leading)

                // Type label
                Text("Artist")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func podcastCard(_ show: PodcastShow) -> some View {
        Button {
            self.navigationPath.append(show)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail
                CachedAsyncImage(url: show.thumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "mic.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 160, height: 160)
                .clipShape(.rect(cornerRadius: 8))

                // Title
                Text(show.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 160, alignment: .leading)

                // Author
                if let author = show.author {
                    Text(author)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            FavoritesContextMenu.menuItem(for: show, manager: self.favoritesManager)
        }
    }
}

// MARK: - LibraryItem

/// Represents a library item that can be a playlist, an artist, or a podcast show.
enum LibraryItem: Identifiable {
    case playlist(Playlist)
    case artist(Artist)
    case podcast(PodcastShow)

    var id: String {
        switch self {
        case let .playlist(playlist):
            "playlist-\(playlist.id)"
        case let .artist(artist):
            "artist-\(artist.id)"
        case let .podcast(show):
            "podcast-\(show.id)"
        }
    }
}

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    LibraryView(viewModel: LibraryViewModel(client: client))
        .environment(PlayerService())
        .environment(FavoritesManager.shared)
}
