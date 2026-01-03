import SwiftUI

// MARK: - PodcastsView

/// Podcasts discovery view displaying podcast shows and episodes.
@available(macOS 26.0, *)
struct PodcastsView: View {
    @State var viewModel: PodcastsViewModel
    @Environment(PlayerService.self) private var playerService
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
            PodcastShowCard(show: show) {
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
                    if let duration = episode.duration {
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

    @State private var episodes: [PodcastEpisode] = []
    @State private var loadingState: LoadingState = .idle

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
        .navigationTitle(self.show.title)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
        }
        .task {
            await self.loadShow()
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

                // Play button
                if let firstEpisode = episodes.first {
                    Button {
                        self.playEpisode(firstEpisode)
                    } label: {
                        Label("Play Latest", systemImage: "play.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var episodesList: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Episodes")
                .font(.title2)
                .fontWeight(.semibold)

            if self.loadingState == .loading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(self.episodes) { episode in
                        PodcastEpisodeRow(episode: episode) {
                            self.playEpisode(episode)
                        }
                        Divider()
                    }
                }
            }
        }
    }

    private func loadShow() async {
        guard self.loadingState == .idle else { return }
        self.loadingState = .loading

        // For now, we don't have a dedicated API method for show detail
        // This would need to be added to YTMusicClient
        // Placeholder: show is already passed in, just mark as loaded
        self.loadingState = .loaded
    }

    private func playEpisode(_ episode: PodcastEpisode) {
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
                        if let duration = episode.duration {
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

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    PodcastsView(viewModel: PodcastsViewModel(client: client))
        .environment(PlayerService())
}
