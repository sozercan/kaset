import SwiftUI

// MARK: - SearchView

/// Search view for finding music.
struct SearchView: View {
    @State var viewModel: SearchViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(AuthService.self) private var authService
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
                    .zIndex(1)

                Divider()

                // Content
                self.contentView
            }
            .localizedNavigationTitle("Search")
            .navigationDestinations(
                client: self.viewModel.client,
                playerBarNavigationAction: self.playerBarNavigationAction
            )
            .playerBarMusicNavigation(path: self.$navigationPath)
        }
        .playerBarMusicNavigation(path: self.$navigationPath)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
                .playerBarMusicNavigation(path: self.$navigationPath)
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
        .popsNavigationStackOnSidebarReselect(path: self.$navigationPath, for: .search)
    }

    private var playerBarNavigationAction: PlayerBarNavigationAction {
        PlayerBarNavigationAction(
            openArtist: { self.navigationPath.append($0) },
            openAlbum: { self.navigationPath.append($0) }
        )
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        VStack(spacing: 12) {
            // Keep suggestions as an overlay of the field itself. If the dropdown participates
            // in the search bar's layout, macOS 26 glass materialization can render a
            // second transient plate during updates. Anchoring it as an overlay gives the
            // autocomplete menu a single visual owner and prevents duplicate dropdowns.
            self.searchField
                .overlay(alignment: .top) {
                    if self.viewModel.showSuggestions {
                        self.suggestionsDropdown
                            .padding(.top, 44) // Below search field
                    }
                }
                .zIndex(1)

            // Filter chips
            if self.viewModel.shouldShowFilters {
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

            TextField(String(localized: "Search songs, albums, artists..."), text: self.$viewModel.query)
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
                .accessibilityIdentifier(AccessibilityID.Search.searchField)

            if !self.viewModel.query.isEmpty {
                Button {
                    self.viewModel.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear search"))
                .accessibilityIdentifier(AccessibilityID.Search.clearButton)
            }
        }
        .padding(10)
        .compatGlass(in: .capsule)
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
        .compatGlass(in: .rect(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        .accessibilityIdentifier(AccessibilityID.Search.suggestionsContainer)
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
        .accessibilityIdentifier(AccessibilityID.Search.suggestion(index: index))
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
            Text(filter.displayName)
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
                title: String(localized: "No Connection"),
                message: String(localized: "Please check your internet connection and try again.")
            ) {
                self.viewModel.search()
            }
        } else {
            switch self.viewModel.loadingState {
            case .idle:
                self.emptyStateView
            case .loading:
                LoadingView(String(localized: "Searching..."))
            case .loaded, .loadingMore:
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

            Text(self.viewModel.query.isEmpty ? String(localized: "Search for your favorite music") : String(localized: "Press Enter to search"))
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(String(localized: "Find songs, albums, artists, and playlists"))
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

            Text(String(localized: "No results found"))
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(String(localized: "Try searching for something else"))
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
    @ViewBuilder
    private var loadMoreView: some View {
        if self.viewModel.loadingState == .loadingMore {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Loading more...", comment: "Shown while loading more search results")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else {
            Button {
                Task { await self.viewModel.loadMore() }
            } label: {
                Text("Load More", comment: "Button to load more search results")
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

    private func resultRow(_ item: SearchResultItem, index: Int) -> some View {
        HoverObservingRow { isHovered in
            Button {
                self.handleItemTap(item)
            } label: {
                HStack(spacing: 12) {
                    // Thumbnail
                    CachedAsyncImage(url: item.thumbnailURL?.highQualityThumbnailURL, targetSize: CGSize(width: 48, height: 48)) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Rectangle()
                            .fill(.quaternary)
                            .overlay {
                                Image(systemName: self.iconForItem(item))
                                    .foregroundStyle(.secondary)
                            }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(.rect(cornerRadius: item.usesCircularThumbnail ? 24 : 6))

                    // Info
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(.system(size: 14))
                                .lineLimit(1)
                            if let song = self.songResultPayload(for: item), song.isExplicit == true {
                                ExplicitBadge()
                            }
                        }

                        HStack(spacing: 4) {
                            Text(item.resultType)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)

                            if let subtitle = item.subtitle {
                                Text(String(localized: "•"))
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

                    // Favorite toggle for songs
                    if let song = self.songResultPayload(for: item) {
                        LikeButton(song: song, isRowHovered: isHovered, allowsActions: self.authService.hasPersonalAccount)
                    }

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
            .accessibilityIdentifier(AccessibilityID.Search.resultRow(index: index))
        }
        .contextMenu {
            SearchResultItemContextMenu(
                item: item,
                client: self.viewModel.client,
                play: { self.handleItemTap(item) },
                navigate: { self.navigationPath.append($0) }
            )
        }
    }

    // MARK: - Helpers

    private func iconForItem(_ item: SearchResultItem) -> String {
        switch item {
        case .song:
            "music.note"
        case .video:
            "play.rectangle"
        case .album:
            "square.stack"
        case .audiobook:
            "books.vertical"
        case .artist:
            "person"
        case .profile:
            "person.crop.circle"
        case .playlist:
            "music.note.list"
        case .podcastShow:
            "mic.fill"
        case .podcastEpisode:
            "mic.badge.plus"
        }
    }

    private func handleItemTap(_ item: SearchResultItem) {
        switch item {
        case let .song(song), let .video(song):
            // Play the song and fetch similar songs (radio queue) in the background
            Task {
                await self.playerService.playWithRadio(song: song)
            }
        case let .artist(artist), let .profile(artist):
            self.navigationPath.append(artist)
        case let .album(album), let .audiobook(album):
            // Navigate as playlist for now
            let playlist = Playlist(
                id: album.id,
                title: album.title,
                description: nil,
                thumbnailURL: album.thumbnailURL,
                trackCount: album.trackCount,
                author: Artist.inline(name: album.artistsDisplay, namespace: "album-artist")
            )
            self.navigationPath.append(playlist)
        case let .playlist(playlist):
            self.navigationPath.append(playlist)
        case let .podcastShow(show):
            self.navigationPath.append(show)
        case let .podcastEpisode(episode):
            Task {
                await self.playerService.play(song: episode.playbackSong)
            }
        }
    }

    private func songResultPayload(for item: SearchResultItem) -> Song? {
        switch item {
        case let .song(song), let .video(song):
            song
        default:
            nil
        }
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
