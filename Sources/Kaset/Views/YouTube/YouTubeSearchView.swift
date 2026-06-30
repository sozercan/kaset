import SwiftUI

// MARK: - YouTubeSearchView

/// YouTube search: query field, result-kind filter, and mixed result list.
struct YouTubeSearchView: View {
    @Bindable var viewModel: YouTubeSearchViewModel
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            self.searchHeader

            Group {
                switch self.viewModel.loadingState {
                case .idle:
                    self.emptyState
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
                        .task {
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
}
