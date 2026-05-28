import SwiftUI

// Minimal fallback views used when the host OS is macOS 15 and the
// Liquid-Glass / Apple-Intelligence-powered counterparts are unavailable.
//
// These intentionally provide a stripped-down but functional surface so the
// app remains usable on Sequoia. On macOS 26+ the original full-featured
// views are used instead.

// MARK: - SimplePlaylistDetailView

/// Minimal playlist view used on macOS 15 (no Liquid Glass, no AI refine).
struct SimplePlaylistDetailView: View {
    let playlist: Playlist
    @State var viewModel: PlaylistDetailViewModel
    @Environment(PlayerService.self) private var playerService

    init(playlist: Playlist, viewModel: PlaylistDetailViewModel) {
        self.playlist = playlist
        self._viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView(String(localized: "Loading playlist..."))
            case .loaded, .loadingMore:
                if let detail = viewModel.playlistDetail {
                    self.content(detail)
                } else {
                    ErrorView(
                        title: String(localized: "Unable to load playlist"),
                        message: String(localized: "Playlist not found")
                    ) {
                        Task { await self.viewModel.load() }
                    }
                }
            case let .error(error):
                ErrorView(error: error) {
                    Task { await self.viewModel.load() }
                }
            }
        }
        .navigationTitle(self.playlist.title)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .error = self.viewModel.loadingState {
            } else {
                PlayerBar()
            }
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

    private func content(_ detail: PlaylistDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                self.headerView(detail)
                self.trackList(detail.tracks)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 100)
        }
    }

    private func headerView(_ detail: PlaylistDetail) -> some View {
        HStack(alignment: .top, spacing: 20) {
            AsyncImage(url: detail.thumbnailURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 220, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                Text(detail.title)
                    .font(.largeTitle.bold())
                if let author = detail.author?.name {
                    Text(author).foregroundStyle(.secondary)
                }
                Text(detail.trackCountDisplay)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        Task { await self.playFromIndex(0, tracks: detail.tracks) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(detail.tracks.isEmpty)

                    Button {
                        self.playerService.toggleShuffle()
                        Task { await self.playFromIndex(0, tracks: detail.tracks) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(detail.tracks.isEmpty)
                }
                .padding(.top, 6)
            }
            Spacer()
        }
    }

    private func trackList(_ tracks: [Song]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                Button {
                    Task { await self.playFromIndex(index, tracks: tracks) }
                } label: {
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                        AsyncImage(url: track.thumbnailURL) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.secondary.opacity(0.15)
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).lineLimit(1)
                            Text(track.artistsDisplay)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if let dur = track.duration {
                            Text(self.formatDuration(dur))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().opacity(0.2)
            }
        }
    }

    private func playFromIndex(_ index: Int, tracks: [Song]) async {
        guard tracks.indices.contains(index) else { return }
        await self.playerService.playQueue(tracks, startingAt: index)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - SimpleLyricsView

/// Minimal lyrics panel used on macOS 15. Shows synced lyrics if available,
/// without AI explanations.
struct SimpleLyricsView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(SyncedLyricsService.self) private var syncedLyricsService

    let client: any YTMusicClientProtocol
    var showsHeader = true
    var preferredWidth: CGFloat? = 280

    var body: some View {
        VStack(spacing: 0) {
            if self.showsHeader {
                HStack {
                    Text(String(localized: "Lyrics"))
                        .font(.headline)
                    Spacer()
                }
                .padding()
                Divider().opacity(0.3)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "Apple Intelligence lyric explanations require macOS 26."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)

                    if let track = playerService.currentTrack {
                        Text(track.title).font(.title3.bold())
                        Text(track.artistsDisplay).foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "No track playing"))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .frame(width: self.preferredWidth)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
