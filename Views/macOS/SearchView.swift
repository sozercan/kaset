import SwiftUI

// MARK: - SearchView

/// Search view for finding music.
@available(macOS 26.0, *)
struct SearchView: View {
    @State var viewModel: SearchViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(SongLikeStatusManager.self) private var likeStatusManager
    @State private var navigationPath = NavigationPath()
    @State private var networkMonitor = NetworkMonitor.shared

    /// External trigger for focusing the search field (from keyboard shortcut).
    @Binding var focusTrigger: Bool

    @FocusState private var isSearchFieldFocused: Bool

    /// Index of currently selected suggestion for keyboard navigation.
    @State private var selectedSuggestionIndex: Int = -1

    /// Initializes SearchView with optional focus trigger binding.
    init(viewModel: SearchViewModel, focusTrigger: Binding<Bool> = .constant(false)) {
        _viewModel = State(initialValue: viewModel)
        _focusTrigger = focusTrigger
    }

    var body: some View {
        NavigationStack(path: self.$navigationPath) {
            VStack(spacing: 0) {
                // Search bar
                self.searchBar

                Divider()

                // Content
                self.contentView
            }
            .navigationTitle("Search")
            .navigationDestinations(client: self.viewModel.client)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
        }
        .onAppear {
            self.isSearchFieldFocused = true
        }
        .onChange(of: self.focusTrigger) { _, newValue in
            if newValue {
                self.isSearchFieldFocused = true
                self.focusTrigger = false
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .top) {
                // Search field
                self.searchField

                // Suggestions dropdown
                if self.viewModel.showSuggestions {
                    self.suggestionsDropdown
                        .padding(.top, 44) // Below search field
                }
            }

            // Filter chips
            if !self.viewModel.results.isEmpty {
                self.filterChips
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .onChange(of: self.viewModel.query) { _, _ in
            self.selectedSuggestionIndex = -1
            self.viewModel.fetchSuggestions()
        }
        .onChange(of: self.viewModel.suggestions) { _, _ in
            self.selectedSuggestionIndex = -1
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search songs, albums, artists...", text: self.$viewModel.query)
                .textFieldStyle(.plain)
                .focused(self.$isSearchFieldFocused)
                .onSubmit {
                    HapticService.success()
                    if self.selectedSuggestionIndex >= 0,
                       self.selectedSuggestionIndex < self.viewModel.suggestions.count
                    {
                        self.viewModel.selectSuggestion(self.viewModel.suggestions[self.selectedSuggestionIndex])
                    } else {
                        self.viewModel.search()
                    }
                }
                .onKeyPress(.downArrow) {
                    if self.viewModel.showSuggestions {
                        self.selectedSuggestionIndex = min(
                            self.selectedSuggestionIndex + 1,
                            self.viewModel.suggestions.count - 1
                        )
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.upArrow) {
                    if self.viewModel.showSuggestions {
                        self.selectedSuggestionIndex = max(self.selectedSuggestionIndex - 1, -1)
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.escape) {
                    if self.viewModel.showSuggestions {
                        self.viewModel.clearSuggestions()
                        return .handled
                    }
                    return .ignored
                }

            if !self.viewModel.query.isEmpty {
                Button {
                    self.viewModel.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(10)
        .glassEffect(.regular, in: .capsule)
    }

    private var suggestionsDropdown: some View {
        VStack(spacing: 0) {
            ForEach(Array(self.viewModel.suggestions.prefix(7).enumerated()), id: \.element.id) { index, suggestion in
                self.suggestionRow(suggestion, index: index)
                if index < min(self.viewModel.suggestions.count, 7) - 1 {
                    Divider()
                        .padding(.leading, 40)
                }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
        .glassEffectTransition(.materialize)
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
    }

    private func suggestionRow(_ suggestion: SearchSuggestion, index: Int) -> some View {
        Button {
            self.viewModel.selectSuggestion(suggestion)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Text(suggestion.query)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.up.left")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(index == self.selectedSuggestionIndex ? Color.accentColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchViewModel.SearchFilter.allCases) { filter in
                    self.filterChip(filter)
                }
            }
        }
    }

    private func filterChip(_ filter: SearchViewModel.SearchFilter) -> some View {
        Button {
            withAnimation(AppAnimation.spring) {
                self.viewModel.selectedFilter = filter
            }
        } label: {
            Text(filter.rawValue)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(self.viewModel.selectedFilter == filter ? Color.accentColor : Color.secondary.opacity(0.2))
                .foregroundStyle(self.viewModel.selectedFilter == filter ? .white : .primary)
                .clipShape(.capsule)
        }
        .buttonStyle(.chip(isSelected: self.viewModel.selectedFilter == filter))
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        if !self.networkMonitor.isConnected {
            ErrorView(
                title: "No Connection",
                message: "Please check your internet connection and try again."
            ) {
                self.viewModel.search()
            }
        } else {
            switch self.viewModel.loadingState {
            case .idle:
                self.emptyStateView
            case .loading, .loadingMore:
                LoadingView("Searching...")
            case .loaded:
                if self.viewModel.filteredItems.isEmpty {
                    self.noResultsView
                } else {
                    self.resultsView
                }
            case let .error(error):
                ErrorView(error: error) {
                    self.viewModel.search()
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text(self.viewModel.query.isEmpty ? "Search for your favorite music" : "Press Enter to search")
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
                ForEach(Array(self.viewModel.filteredItems.enumerated()), id: \.element.id) { index, item in
                    self.resultRow(item, index: index)
                    Divider()
                        .padding(.leading, 72)
                }

                // Load more indicator / button
                if self.viewModel.hasMoreResults {
                    self.loadMoreView
                }
            }
            .padding(.vertical, 8)
        }
    }

    /// Load more view that triggers pagination when visible.
    private var loadMoreView: some View {
        Group {
            if self.viewModel.loadingState == .loadingMore {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading more...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                Button {
                    Task { await self.viewModel.loadMore() }
                } label: {
                    Text("Load More")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.plain)
                .onAppear {
                    // Auto-load more when this view appears (infinite scroll)
                    Task { await self.viewModel.loadMore() }
                }
            }
        }
    }

    private func resultRow(_ item: SearchResultItem, index: Int) -> some View {
        Button {
            self.handleItemTap(item)
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
                            Image(systemName: self.iconForItem(item))
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
        .buttonStyle(.interactiveRow(cornerRadius: 6))
        .staggeredAppearance(index: min(index, 10))
        .contextMenu {
            self.contextMenuItems(for: item)
        }
    }

    @ViewBuilder
    private func contextMenuItems(for item: SearchResultItem) -> some View {
        switch item {
        case let .song(song):
            Button {
                Task { await self.playerService.play(song: song) }
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
                self.navigationPath.append(playlist)
            } label: {
                Label("View Album", systemImage: "square.stack")
            }

            Divider()

            FavoritesContextMenu.menuItem(for: album, manager: self.favoritesManager)

            ShareContextMenu.menuItem(for: album)

        case let .artist(artist):
            Button {
                self.navigationPath.append(artist)
            } label: {
                Label("View Artist", systemImage: "person")
            }

            Divider()

            FavoritesContextMenu.menuItem(for: artist, manager: self.favoritesManager)

            ShareContextMenu.menuItem(for: artist)

        case let .playlist(playlist):
            Button {
                Task {
                    await SongActionsHelper.addPlaylistToLibrary(playlist, client: self.viewModel.client)
                }
            } label: {
                Label("Add to Library", systemImage: "plus.circle")
            }

            Divider()

            FavoritesContextMenu.menuItem(for: playlist, manager: self.favoritesManager)

            Divider()

            ShareContextMenu.menuItem(for: playlist)

            Divider()

            Button {
                self.navigationPath.append(playlist)
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
            // Play the song and fetch similar songs (radio queue) in the background
            Task {
                await self.playerService.playWithRadio(song: song)
            }
        case let .artist(artist):
            self.navigationPath.append(artist)
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
            self.navigationPath.append(playlist)
        case let .playlist(playlist):
            self.navigationPath.append(playlist)
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
        .environment(FavoritesManager.shared)
}
