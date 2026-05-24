import SwiftUI

// MARK: - DownloadsView

/// View displaying all downloaded songs available for offline access.
@available(macOS 26.0, *)
struct DownloadsView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(SongLikeStatusManager.self) private var likeStatusManager
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: self.$navigationPath) {
            Group {
                if OfflineService.shared.downloadedSongs.isEmpty {
                    self.emptyState
                } else {
                    self.songList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .localizedNavigationTitle("Downloads")
            .navigationDestinations(client: self.playerService.ytMusicClient ?? YTMusicClient(authService: AuthService(), webKitManager: .shared))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No Downloaded Songs")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Text("Songs you download will appear here for quick access.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Song List

    private var songList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                self.headerSection

                ForEach(OfflineService.shared.downloadedSongs) { song in
                    self.songRow(song)

                    if song.id != OfflineService.shared.downloadedSongs.last?.id {
                        Divider()
                            .padding(.leading, 72)
                            .opacity(0.3)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloads")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("\(OfflineService.shared.downloadCount) songs")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !OfflineService.shared.downloadedSongs.isEmpty {
                Button {
                    Task {
                        let songs = OfflineService.shared.downloadedSongs
                        guard let first = songs.first else { return }
                        await self.playerService.play(song: first)
                        self.playerService.appendToQueue(Array(songs.dropFirst()))
                    }
                } label: {
                    Label("Play All", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(role: .destructive) {
                    OfflineService.shared.clearAllDownloads()
                } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(.bottom, 20)
    }

    private func songRow(_ song: Song) -> some View {
        HStack(spacing: 12) {
            SongThumbnailView(song: song, size: 48, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .lineLimit(1)

                Text(song.artistsDisplay.isEmpty ? String(localized: "Unknown Artist") : song.artistsDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let duration = song.duration {
                Text(self.formatDuration(duration))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                await self.playerService.play(song: song)
            }
        }
        .contextMenu {
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

            AddToQueueContextMenu(song: song, playerService: self.playerService)

            Divider()

            ShareContextMenu.menuItem(for: song)

            Divider()

            Button(role: .destructive) {
                OfflineService.shared.removeSong(videoId: song.videoId)
            } label: {
                Label("Remove Download", systemImage: "trash")
            }

            Divider()

            if let artist = song.artists.first(where: { $0.hasNavigableId }) {
                NavigationLink(value: artist) {
                    Label("Go to Artist", systemImage: "person")
                }
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

@available(macOS 26.0, *)
#Preview {
    DownloadsView()
        .environment(PlayerService())
        .environment(FavoritesManager.shared)
        .environment(SongLikeStatusManager.shared)
}
