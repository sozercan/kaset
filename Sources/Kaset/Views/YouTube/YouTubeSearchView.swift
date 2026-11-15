import SwiftUI

// MARK: - YouTubeSearchView

/// YouTube search: query field, result-kind filter, and mixed result list.
struct YouTubeSearchView: View {
    @Bindable var viewModel: YouTubeSearchViewModel
    @FocusState private var isSearchFieldFocused: Bool
    @State private var showsHistoryFailure = false

    /// Google's page for reviewing and deleting YouTube search history.
    private static let manageHistoryURL = URL(string: "https://myactivity.google.com/product/youtube")

    var body: some View {
        VStack(spacing: 0) {
            self.searchHeader

            Group {
                switch self.viewModel.loadingState {
                case .idle:
                    self.idleContent
                case .loading:
                    LoadingView()
                case let .error(error):
                    ErrorView(
                        title: error.title,
                        message: error.message,
                        isRetryable: error.isRetryable
                    ) {
                        Task {
                            await self.viewModel.search()
                        }
                    }
                case .loaded, .loadingMore:
                    if self.viewModel.results.isEmpty {
                        ContentUnavailableView.search(text: self.viewModel.query)
                    } else {
                        self.resultsList
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(Text("Search", comment: "YouTube search title"))
        .task(id: self.isIdle) {
            guard self.isIdle else { return }
            await self.viewModel.loadAccountSearchHistory()
        }
        .overlay(alignment: .top) {
            if self.showsHistoryFailure {
                ToastView(
                    message: String(localized: "Couldn't update YouTube search history."),
                    isError: true
                ) {
                    self.showsHistoryFailure = false
                }
                .padding(.top, 12)
                .task(id: self.viewModel.searchHistoryFailureCount) {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    self.showsHistoryFailure = false
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: self.showsHistoryFailure)
        .onChange(of: self.viewModel.searchHistoryFailureCount) { _, _ in
            self.showsHistoryFailure = true
        }
    }

    private var isIdle: Bool {
        if case .idle = self.viewModel.loadingState {
            return true
        }
        return false
    }

    // MARK: - Header

    private var searchHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(
                    String(localized: "Search YouTube"),
                    text: self.$viewModel.query
                )
                .textFieldStyle(.plain)
                .focused(self.$isSearchFieldFocused)
                .onSubmit {
                    Task {
                        await self.viewModel.search()
                    }
                }
                .accessibilityIdentifier(AccessibilityID.YouTubeContent.searchField)

                if !self.viewModel.query.isEmpty {
                    Button {
                        self.viewModel.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Clear search"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5), in: Capsule())

            Picker(String(localized: "Filter"), selection: self.$viewModel.selectedFilter) {
                ForEach(YouTubeSearchFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.searchFilter)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - History

    /// Search history while nothing has been searched yet, narrowed to what is
    /// typed; the plain empty state when there is no history to show.
    @ViewBuilder
    private var idleContent: some View {
        let recent = self.viewModel.visibleRecentSearches
        let account = self.viewModel.visibleAccountSearchHistory
        if recent.isEmpty, account.isEmpty, !self.viewModel.isLoadingAccountSearchHistory {
            self.emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !recent.isEmpty {
                        self.historyHeader(String(localized: "Recent searches")) {
                            Button(String(localized: "Clear")) {
                                self.viewModel.clearRecentSearches()
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier(AccessibilityID.YouTubeContent.clearRecentSearches)
                        }
                        ForEach(recent, id: \.self) { entry in
                            self.historyRow(entry, systemImage: "clock.arrow.circlepath")
                        }
                    }

                    if !account.isEmpty || self.viewModel.isLoadingAccountSearchHistory {
                        self.historyHeader(String(localized: "YouTube search history")) {
                            if self.viewModel.isLoadingAccountSearchHistory {
                                ProgressView()
                                    .controlSize(.small)
                            } else if let url = Self.manageHistoryURL {
                                Link(String(localized: "Manage"), destination: url)
                                    .help(String(localized: "Review and delete YouTube search history in your Google Account"))
                            }
                        }
                        .padding(.top, recent.isEmpty ? 0 : 12)
                        ForEach(account, id: \.self) { entry in
                            self.historyRow(entry, systemImage: "magnifyingglass")
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.searchHistory)
        }
    }

    private func historyHeader(
        _ title: String,
        @ViewBuilder accessory: () -> some View
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.bold())
            Spacer()
            accessory()
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func historyRow(_ entry: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Button {
                self.isSearchFieldFocused = false
                Task {
                    await self.viewModel.search(historyEntry: entry)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(entry)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.interactiveRow)

            Button {
                Task {
                    await self.viewModel.removeSearchHistoryEntry(entry)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Remove from search history"))
            .accessibilityLabel(String(localized: "Remove from search history"))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "Search YouTube"), systemImage: "magnifyingglass")
        } description: {
            Text("Find videos, channels, and playlists.", comment: "YouTube search empty state")
        }
    }

    // MARK: - Results

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if !self.viewModel.results.channels.isEmpty {
                    self.sectionHeader(String(localized: "Channels"))
                    ForEach(self.viewModel.results.channels) { channel in
                        NavigationLink(value: YouTubeRoute.channel(channelId: channel.channelId)) {
                            ChannelRowView(channel: channel)
                        }
                        .buttonStyle(.interactiveRow)
                    }
                }

                if !self.viewModel.results.videos.isEmpty {
                    if self.viewModel.selectedFilter == .all {
                        self.sectionHeader(String(localized: "Videos"))
                    }
                    ForEach(self.viewModel.results.videos) { video in
                        NavigationLink(value: YouTubeRoute.watch(video)) {
                            VideoRowView(video: video)
                        }
                        .buttonStyle(.interactiveRow)
                    }
                }

                if !self.viewModel.results.playlists.isEmpty {
                    if self.viewModel.selectedFilter == .all {
                        self.sectionHeader(String(localized: "Playlists"))
                    }
                    ForEach(self.viewModel.results.playlists) { playlist in
                        NavigationLink(value: YouTubeRoute.playlist(playlistId: playlist.playlistId)) {
                            YouTubePlaylistRowView(playlist: playlist)
                        }
                        .buttonStyle(.interactiveRow)
                    }
                }

                if self.viewModel.results.continuation != nil {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .task(id: self.viewModel.results.continuation) {
                            await self.viewModel.loadMore()
                        }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.searchResults)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.bold())
            .padding(.top, 8)
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let searchField = "youtubeContent.searchField"
    static let searchFilter = "youtubeContent.searchFilter"
    static let searchResults = "youtubeContent.searchResults"
    static let searchHistory = "youtubeContent.searchHistory"
    static let clearRecentSearches = "youtubeContent.clearRecentSearches"
}
