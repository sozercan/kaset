import SwiftUI

/// View displaying the user's YouTube Music listening history.
/// Fetches history from the API and displays songs grouped by time period.
@available(macOS 26.0, *)
struct HistoryView: View {
    @State var viewModel: HistoryViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @State private var navigationPath = NavigationPath()
    @State private var networkMonitor = NetworkMonitor.shared
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack(path: self.$navigationPath) {
            Group {
                if !self.networkMonitor.isConnected {
                    ErrorView(
                        title: String(localized: "No Connection"),
                        message: String(localized: "Please check your internet connection and try again.")
                    ) {
                        Task { await self.performRefresh() }
                    }
                } else {
                    switch self.viewModel.loadingState {
                    case .idle, .loading:
                        LoadingView(String(localized: "Loading..."))
                    case .loaded, .loadingMore:
                        self.contentView
                    case let .error(error):
                        ErrorView(error: error) {
                            Task { await self.performRefresh() }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .localizedNavigationTitle("Listening History")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await self.performRefresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(self.isRefreshing ? 360 : 0))
                            .animation(
                                self.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                                value: self.isRefreshing
                            )
                    }
                    .help(String(localized: "Refresh"))
                    .disabled(self.isRefreshing)
                }
            }
            .navigationDestinations(client: self.viewModel.client)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
        }
        .task {
            if self.viewModel.loadingState == .idle {
                await self.viewModel.load()
                self.viewModel.syncObservedPlayback(videoId: self.playerService.currentTrack?.videoId)
            }
        }
        .onAppear {
            self.viewModel.schedulePlaybackRefreshIfNeeded(for: self.playerService.currentTrack?.videoId)
        }
        .onChange(of: self.playerService.currentTrack?.videoId) { _, newVideoId in
            self.viewModel.schedulePlaybackRefreshIfNeeded(for: newVideoId)
        }
        .refreshable {
            await self.performRefresh()
        }
    }

    /// Refreshes with visual feedback: spinning icon → data swap.
    @discardableResult
    private func performRefresh() async -> Bool {
        self.isRefreshing = true
        let changed = await self.viewModel.refresh()
        self.isRefreshing = false
        return changed
    }

    // MARK: - Content

    private var headerView: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)

                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "History"))
                    .font(.title2)
                    .fontWeight(.bold)

                let todayCount = self.viewModel.sections.first?.items.count ?? 0
                Text(String(localized: "\(todayCount) songs listened today"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var contentView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                self.headerView
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)

                ForEach(self.viewModel.sections) { section in
                    Text(section.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                        .padding(.bottom, 8)

                    let songs = section.items.compactMap { item -> Song? in
                        if case let .song(song) = item { return song }
                        return nil
                    }

                    ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                        self.songRow(song, allSongs: songs, index: index)
                            .id("\(section.id)-\(index)")
                        if index < songs.count - 1 {
                            Divider()
                                .padding(.leading, 72)
                        }
                    }
                }
            }
            .padding(.vertical, 20)
        }
        .accessibilityIdentifier(AccessibilityID.History.scrollView)
    }

    // MARK: - Song Row

    private func songRow(_ song: Song, allSongs: [Song], index: Int) -> some View {
        Button {
            Task {
                await self.playerService.playQueue(allSongs, startingAt: index)
            }
        } label: {
            HStack(spacing: 12) {
                SongThumbnailView(song: song)

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.system(size: 14))
                        .lineLimit(1)

                    Text(song.artistsDisplay)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(song.durationDisplay)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Image(systemName: "play.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await self.playerService.play(song: song) }
            } label: {
                Label(String(localized: "Play"), systemImage: "play.fill")
            }

            Divider()

            FavoritesContextMenu.menuItem(for: song, manager: self.favoritesManager)

            Divider()

            StartRadioContextMenu.menuItem(for: song, playerService: self.playerService)

            Divider()

            ShareContextMenu.menuItem(for: song)

            Divider()

            AddToQueueContextMenu(song: song, playerService: self.playerService)

            Divider()

            if let artist = song.artists.first(where: { $0.hasNavigableId }) {
                NavigationLink(value: artist) {
                    Label(String(localized: "Go to Artist"), systemImage: "person")
                }
            }

            if let album = song.album, album.hasNavigableId {
                let playlist = Playlist(
                    id: album.id,
                    title: album.title,
                    description: nil,
                    thumbnailURL: album.thumbnailURL ?? song.thumbnailURL,
                    trackCount: album.trackCount,
                    author: Artist.inline(name: album.artistsDisplay, namespace: "album-artist")
                )
                NavigationLink(value: playlist) {
                    Label(String(localized: "Go to Album"), systemImage: "square.stack")
                }
            }
        }
    }
}
