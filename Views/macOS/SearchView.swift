import SwiftUI

// MARK: - SearchView

/// Search view for finding music.
@available(macOS 26.0, *)
struct SearchView: View {
    @State var viewModel: SearchViewModel
    @Environment(PlayerService.self) private var playerService
    @State private var navigationPath = NavigationPath()

    /// External trigger for focusing the search field (from keyboard shortcut).
    @Binding var focusTrigger: Bool

    @FocusState private var isSearchFieldFocused: Bool

    /// Initializes SearchView with optional focus trigger binding.
    init(viewModel: SearchViewModel, focusTrigger: Binding<Bool> = .constant(false)) {
        _viewModel = State(initialValue: viewModel)
        _focusTrigger = focusTrigger
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                // Search bar
                searchBar

                Divider()

                // Content
                contentView
            }
            .navigationTitle("Search")
            .navigationDestinations(client: viewModel.client)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
        }
        .onAppear {
            isSearchFieldFocused = true
        }
        .onChange(of: focusTrigger) { _, newValue in
            if newValue {
                isSearchFieldFocused = true
                focusTrigger = false
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search songs, albums, artists...", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        viewModel.search()
                    }

                if !viewModel.query.isEmpty {
                    Button {
                        viewModel.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5))
            .clipShape(.rect(cornerRadius: 8))

            // Filter chips
            if !viewModel.results.isEmpty {
                filterChips
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .onChange(of: viewModel.query) { _, _ in
            viewModel.search()
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchViewModel.SearchFilter.allCases) { filter in
                    filterChip(filter)
                }
            }
        }
    }

    private func filterChip(_ filter: SearchViewModel.SearchFilter) -> some View {
        Button {
            viewModel.selectedFilter = filter
        } label: {
            Text(filter.rawValue)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(viewModel.selectedFilter == filter ? Color.accentColor : Color.secondary.opacity(0.2))
                .foregroundStyle(viewModel.selectedFilter == filter ? .white : .primary)
                .clipShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.loadingState {
        case .idle:
            emptyStateView
        case .loading, .loadingMore:
            LoadingView("Searching...")
        case .loaded:
            if viewModel.filteredItems.isEmpty {
                noResultsView
            } else {
                resultsView
            }
        case let .error(message):
            ErrorView(title: "Search failed", message: message) {
                viewModel.search()
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("Search for your favorite music")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Find songs, albums, artists, and playlists")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No results found")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Try searching for something else")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.filteredItems) { item in
                    resultRow(item)
                    Divider()
                        .padding(.leading, 72)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func resultRow(_ item: SearchResultItem) -> some View {
        Button {
            handleItemTap(item)
        } label: {
            HStack(spacing: 12) {
                // Thumbnail
                CachedAsyncImage(url: item.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: iconForItem(item))
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 48, height: 48)
                .clipShape(.rect(cornerRadius: item.isArtist ? 24 : 6))

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 14))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(item.resultType)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        if let subtitle = item.subtitle {
                            Text("•")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)

                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                // Play indicator for songs
                if item.videoId != nil {
                    Image(systemName: "play.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            contextMenuItems(for: item)
        }
    }

    @ViewBuilder
    private func contextMenuItems(for item: SearchResultItem) -> some View {
        switch item {
        case let .song(song):
            Button {
                Task { await playerService.play(song: song) }
            } label: {
                Label("Play", systemImage: "play.fill")
            }

            Divider()

            Button {
                SongActionsHelper.likeSong(song, playerService: playerService)
            } label: {
                Label("Like", systemImage: "hand.thumbsup")
            }

            Button {
                SongActionsHelper.dislikeSong(song, playerService: playerService)
            } label: {
                Label("Dislike", systemImage: "hand.thumbsdown")
            }

            Divider()

            Button {
                SongActionsHelper.addToLibrary(song, playerService: playerService)
            } label: {
                Label("Add to Library", systemImage: "plus.circle")
            }

        case let .album(album):
            Button {
                let playlist = Playlist(
                    id: album.id,
                    title: album.title,
                    description: nil,
                    thumbnailURL: album.thumbnailURL,
                    trackCount: album.trackCount,
                    author: album.artistsDisplay
                )
                navigationPath.append(playlist)
            } label: {
                Label("View Album", systemImage: "square.stack")
            }

        case let .artist(artist):
            Button {
                navigationPath.append(artist)
            } label: {
                Label("View Artist", systemImage: "person")
            }

        case let .playlist(playlist):
            Button {
                Task {
                    await SongActionsHelper.addPlaylistToLibrary(playlist, client: viewModel.client)
                }
            } label: {
                Label("Add to Library", systemImage: "plus.circle")
            }

            Button {
                navigationPath.append(playlist)
            } label: {
                Label("View Playlist", systemImage: "music.note.list")
            }
        }
    }

    // MARK: - Helpers

    private func iconForItem(_ item: SearchResultItem) -> String {
        switch item {
        case .song:
            "music.note"
        case .album:
            "square.stack"
        case .artist:
            "person"
        case .playlist:
            "music.note.list"
        }
    }

    private func handleItemTap(_ item: SearchResultItem) {
        switch item {
        case let .song(song):
            Task {
                await playerService.play(videoId: song.videoId)
            }
        case let .artist(artist):
            navigationPath.append(artist)
        case let .album(album):
            // Navigate as playlist for now
            let playlist = Playlist(
                id: album.id,
                title: album.title,
                description: nil,
                thumbnailURL: album.thumbnailURL,
                trackCount: album.trackCount,
                author: album.artistsDisplay
            )
            navigationPath.append(playlist)
        case let .playlist(playlist):
            navigationPath.append(playlist)
        }
    }
}

extension SearchResultItem {
    var isArtist: Bool {
        if case .artist = self { return true }
        return false
    }
}

#Preview {
    @Previewable @State var focusTrigger = false
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    SearchView(viewModel: SearchViewModel(client: client), focusTrigger: $focusTrigger)
        .environment(PlayerService())
}
