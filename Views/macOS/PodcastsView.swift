import SwiftUI

// MARK: - PodcastsView

/// Podcasts discovery view displaying podcast shows and episodes.
@available(macOS 26.0, *)
struct PodcastsView: View {
    @State var viewModel: PodcastsViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @State private var navigationPath = NavigationPath()
    @State private var networkMonitor = NetworkMonitor.shared

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
                        LoadingView("Loading podcasts...")
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
            .navigationTitle("Podcasts")
            .navigationDestination(for: PodcastShow.self) { show in
                PodcastShowView(show: show, client: self.viewModel.client)
            }
            .navigationDestinations(client: self.viewModel.client)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
        }
        .onAppear {
            if self.viewModel.loadingState == .idle {
                Task {
                    await self.viewModel.load()
                }
            }
        }
        .refreshable {
            await self.viewModel.refresh()
        }
    }

    // MARK: - Views

    private var contentView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(self.viewModel.sections) { section in
                    self.sectionView(section)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private func sectionView(_ section: PodcastSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.title2)
                .fontWeight(.semibold)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(section.items) { item in
                        self.itemCard(item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func itemCard(_ item: PodcastSectionItem) -> some View {
        switch item {
        case let .show(show):
            PodcastShowCard(show: show, favoritesManager: self.favoritesManager) {
                self.navigationPath.append(show)
            }
        case let .episode(episode):
            PodcastEpisodeCard(episode: episode) {
                self.playEpisode(episode)
            }
        }
    }

    // MARK: - Actions

    private func playEpisode(_ episode: PodcastEpisode) {
        // Create a Song from the episode to play via WebView
        let song = Song(
            id: episode.id,
            title: episode.title,
            artists: episode.showTitle.map { [Artist(id: "podcast", name: $0)] } ?? [],
            album: nil,
            duration: episode.durationSeconds.map { TimeInterval($0) },
            thumbnailURL: episode.thumbnailURL,
            videoId: episode.id
        )
        Task {
            await self.playerService.play(song: song)
        }
    }
}

// MARK: - PodcastShowCard

@available(macOS 26.0, *)
private struct PodcastShowCard: View {
    let show: PodcastShow
    let favoritesManager: FavoritesManager
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail
                CachedAsyncImage(url: self.show.thumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Title
                Text(self.show.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                // Author
                if let author = show.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 160)
        }
        .buttonStyle(.plain)
        .contextMenu {
            FavoritesContextMenu.menuItem(for: self.show, manager: self.favoritesManager)
        }
    }
}

// MARK: - PodcastEpisodeCard

@available(macOS 26.0, *)
private struct PodcastEpisodeCard: View {
    let episode: PodcastEpisode
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail with play indicator
                ZStack(alignment: .bottomTrailing) {
                    CachedAsyncImage(url: self.episode.thumbnailURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .frame(width: 200, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    // Duration badge
                    if let duration = episode.formattedDuration {
                        Text(duration)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                    }
                }

                // Title
                Text(self.episode.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                // Show name and date
                HStack(spacing: 4) {
                    if let showTitle = episode.showTitle {
                        Text(showTitle)
                            .lineLimit(1)
                    }
                    if self.episode.showTitle != nil, self.episode.publishedDate != nil {
                        Text("•")
                    }
                    if let date = episode.publishedDate {
                        Text(date)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // Progress bar (Apple Podcasts style)
                if self.episode.playbackProgress > 0 {
                    ProgressView(value: self.episode.playbackProgress)
                        .tint(self.episode.isPlayed ? .secondary : .accentColor)
                }
            }
            .frame(width: 200)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - PodcastShowView

/// Detail view for a podcast show with its episodes.
@available(macOS 26.0, *)
struct PodcastShowView: View {
    let show: PodcastShow
    let client: any YTMusicClientProtocol
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager

    @State private var episodes: [PodcastEpisode] = []
    @State private var continuationToken: String?
    @State private var loadingState: LoadingState = .idle
    @State private var isSubscribed: Bool = false
    @State private var isSubscribing: Bool = false
    @State private var showAllEpisodes = false
    @State private var subscriptionError: String?

    /// Number of episodes to show in the preview
    private let previewEpisodeCount = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                self.headerView

                Divider()

                // Episodes list
                self.episodesList
            }
            .padding(24)
        }
        .accentBackground(from: self.show.thumbnailURL)
        .navigationTitle(self.show.title)
        .navigationDestination(for: AllEpisodesDestination.self) { destination in
            AllEpisodesView(
                show: destination.show,
                initialEpisodes: destination.episodes,
                continuationToken: destination.continuationToken,
                client: self.client
            )
        }
        .navigationDestination(isPresented: self.$showAllEpisodes) {
            AllEpisodesView(
                show: self.show,
                initialEpisodes: self.episodes,
                continuationToken: self.continuationToken,
                client: self.client
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
        }
        .task {
            await self.loadShow()
        }
        .alert(
            "Subscription Error",
            isPresented: Binding(
                get: { self.subscriptionError != nil },
                set: { if !$0 { self.subscriptionError = nil } }
            )
        ) {
            Button("OK") { self.subscriptionError = nil }
        } message: {
            Text(self.subscriptionError ?? "An unknown error occurred")
        }
    }

    private var headerView: some View {
        HStack(alignment: .top, spacing: 20) {
            // Artwork
            CachedAsyncImage(url: self.show.thumbnailURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .frame(width: 180, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contextMenu {
                FavoritesContextMenu.menuItem(for: self.show, manager: self.favoritesManager)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(self.show.title)
                    .font(.title)
                    .fontWeight(.bold)

                if let author = show.author {
                    Text(author)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                if let description = show.description {
                    Text(description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }

                Spacer()

                // Action buttons
                HStack(spacing: 12) {
                    // Play button - plays from the first episode and queues the rest
                    if !self.episodes.isEmpty {
                        Button {
                            self.playEpisodeInQueue(at: 0)
                        } label: {
                            Label("Play Latest", systemImage: "play.fill")
                                .font(.headline)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    // Add to Library button
                    Button {
                        Task {
                            await self.toggleSubscription()
                        }
                    } label: {
                        if self.isSubscribing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(
                                self.isSubscribed ? "In Library" : "Add to Library",
                                systemImage: self.isSubscribed ? "checkmark" : "plus"
                            )
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(self.isSubscribing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var episodesList: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with "Show All" button
            HStack {
                Text("Episodes")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                if self.episodes.count > self.previewEpisodeCount || self.continuationToken != nil {
                    Button {
                        self.showAllEpisodes = true
                    } label: {
                        Text("Show All")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.accent)
                }
            }

            if self.loadingState == .loading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(self.previewEpisodes.enumerated()), id: \.element.id) { index, episode in
                        PodcastEpisodeRow(episode: episode) {
                            self.playEpisodeInQueue(at: index)
                        }
                        Divider()
                    }
                }
            }
        }
    }

    /// Episodes to show in the preview (limited to previewEpisodeCount)
    private var previewEpisodes: [PodcastEpisode] {
        Array(self.episodes.prefix(self.previewEpisodeCount))
    }

    private func loadShow() async {
        guard self.loadingState == .idle else { return }
        self.loadingState = .loading

        do {
            let showDetail = try await client.getPodcastShow(browseId: self.show.id)
            self.episodes = showDetail.episodes
            self.continuationToken = showDetail.continuationToken
            self.isSubscribed = showDetail.isSubscribed
            self.loadingState = .loaded
        } catch {
            DiagnosticsLogger.api.error("Failed to load podcast show: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Plays an episode and queues the remaining episodes from the show.
    private func playEpisodeInQueue(at index: Int) {
        let songs = self.episodes.map { self.episodeToSong($0) }
        Task {
            await self.playerService.playQueue(songs, startingAt: index)
        }
    }

    /// Converts a podcast episode to a Song for playback.
    private func episodeToSong(_ episode: PodcastEpisode) -> Song {
        Song(
            id: episode.id,
            title: episode.title,
            artists: episode.showTitle.map { [Artist(id: "podcast", name: $0)] } ?? [],
            album: nil,
            duration: episode.durationSeconds.map { TimeInterval($0) },
            thumbnailURL: episode.thumbnailURL,
            videoId: episode.id
        )
    }

    private func toggleSubscription() async {
        self.isSubscribing = true
        defer { self.isSubscribing = false }

        do {
            if self.isSubscribed {
                try await self.client.unsubscribeFromPodcast(showId: self.show.id)
                self.isSubscribed = false
                // Update LibraryViewModel for immediate UI update in library view
                if let libraryVM = LibraryViewModel.shared {
                    libraryVM.removeFromLibrary(podcastId: self.show.id)
                } else {
                    DiagnosticsLogger.api.warning(
                        "LibraryViewModel.shared is nil - library UI may be stale after unsubscribing from podcast")
                }
            } else {
                try await self.client.subscribeToPodcast(showId: self.show.id)
                self.isSubscribed = true
                // Update LibraryViewModel for immediate UI update in library view
                if let libraryVM = LibraryViewModel.shared {
                    libraryVM.addToLibrary(podcast: self.show)
                } else {
                    DiagnosticsLogger.api.warning(
                        "LibraryViewModel.shared is nil - library UI may be stale after subscribing to podcast")
                }
            }
        } catch {
            let errorMessage = error.localizedDescription
            DiagnosticsLogger.api.error(
                "Failed to toggle podcast subscription for \(self.show.title): \(errorMessage)")
            self.subscriptionError = errorMessage
        }
    }
}

// MARK: - PodcastEpisodeRow

@available(macOS 26.0, *)
struct PodcastEpisodeRow: View {
    let episode: PodcastEpisode
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(alignment: .top, spacing: 12) {
                // Thumbnail
                CachedAsyncImage(url: self.episode.thumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 4) {
                    // Title
                    HStack {
                        Text(self.episode.title)
                            .font(.headline)
                            .lineLimit(2)
                        Spacer()
                        if let duration = episode.formattedDuration {
                            Text(duration)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Description
                    if let description = episode.description {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    // Date and progress
                    HStack {
                        if let date = episode.publishedDate {
                            Text(date)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if self.episode.isPlayed {
                            Label("Played", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Progress bar
                    if self.episode.playbackProgress > 0, !self.episode.isPlayed {
                        ProgressView(value: self.episode.playbackProgress)
                            .tint(.accentColor)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AllEpisodesDestination

/// Navigation destination for the all episodes view.
struct AllEpisodesDestination: Hashable {
    let show: PodcastShow
    let episodes: [PodcastEpisode]
    let continuationToken: String?

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.show.id)
    }

    static func == (lhs: AllEpisodesDestination, rhs: AllEpisodesDestination) -> Bool {
        lhs.show.id == rhs.show.id
    }
}

// MARK: - AllEpisodesView

/// View displaying all episodes of a podcast show with infinite scroll pagination.
@available(macOS 26.0, *)
struct AllEpisodesView: View {
    let show: PodcastShow
    let initialEpisodes: [PodcastEpisode]
    let continuationToken: String?
    let client: any YTMusicClientProtocol

    @Environment(PlayerService.self) private var playerService
    @State private var episodes: [PodcastEpisode] = []
    @State private var currentContinuationToken: String?
    @State private var isLoadingMore = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(self.episodes.enumerated()), id: \.element.id) { index, episode in
                    PodcastEpisodeRow(episode: episode) {
                        self.playEpisodeInQueue(at: index)
                    }
                    Divider()

                    // Infinite scroll trigger - load more when near the end
                    if episode.id == self.episodes.last?.id, self.currentContinuationToken != nil {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                            .onAppear {
                                Task {
                                    await self.loadMoreEpisodes()
                                }
                            }
                    }
                }
            }
            .padding(24)
        }
        .accentBackground(from: self.show.thumbnailURL)
        .navigationTitle("All Episodes")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
        }
        .onAppear {
            // Initialize with episodes passed from parent
            if self.episodes.isEmpty {
                self.episodes = self.initialEpisodes
                self.currentContinuationToken = self.continuationToken
            }
        }
    }

    private func loadMoreEpisodes() async {
        guard !self.isLoadingMore, let token = self.currentContinuationToken else { return }
        self.isLoadingMore = true
        defer { self.isLoadingMore = false }

        do {
            let continuation = try await self.client.getPodcastEpisodesContinuation(token: token)
            self.episodes.append(contentsOf: continuation.episodes)
            self.currentContinuationToken = continuation.continuationToken
            DiagnosticsLogger.api.info("Loaded \(continuation.episodes.count) more episodes")
        } catch {
            DiagnosticsLogger.api.error("Failed to load more episodes: \(error.localizedDescription)")
        }
    }

    /// Plays an episode and queues the remaining episodes.
    private func playEpisodeInQueue(at index: Int) {
        let songs = self.episodes.map { self.episodeToSong($0) }
        Task {
            await self.playerService.playQueue(songs, startingAt: index)
        }
    }

    /// Converts a podcast episode to a Song for playback.
    private func episodeToSong(_ episode: PodcastEpisode) -> Song {
        Song(
            id: episode.id,
            title: episode.title,
            artists: episode.showTitle.map { [Artist(id: "podcast", name: $0)] } ?? [],
            album: nil,
            duration: episode.durationSeconds.map { TimeInterval($0) },
            thumbnailURL: episode.thumbnailURL,
            videoId: episode.id
        )
    }
}

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    PodcastsView(viewModel: PodcastsViewModel(client: client))
        .environment(PlayerService())
}
