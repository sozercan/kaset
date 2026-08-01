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
    let playerBarNavigationAction: PlayerBarNavigationAction
    @State var viewModel: PlaylistDetailViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(SongLikeStatusManager.self) private var likeStatusManager

    init(
        playlist: Playlist,
        viewModel: PlaylistDetailViewModel,
        playerBarNavigationAction: PlayerBarNavigationAction = .disabled
    ) {
        self.playlist = playlist
        self.playerBarNavigationAction = playerBarNavigationAction
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
                    .environment(\.playerBarNavigationAction, self.playerBarNavigationAction)
                    .environment(\.playerBarCurrentAlbumID, self.playlist.isAlbum ? self.playlist.id : nil)
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
        .onChange(of: self.likeStatusManager.lastLikeEventBatch) { _, batch in
            guard let batch, batch.accountID == self.likeStatusManager.activeAccountID else { return }
            for event in batch.events {
                guard LikedMusicPlaylist.matches(id: self.playlist.id) else { return }
                self.viewModel.handleLikeStatusChange(event)
            }
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
        let playableTracks = self.playableTracks(in: detail.tracks)

        return HStack(alignment: .top, spacing: 20) {
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
                        Task { await self.play(playableTracks, startingAt: 0) }
                    } label: {
                        Label(String(localized: "Play"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(playableTracks.isEmpty)

                    Button {
                        if !self.playerService.shuffleEnabled {
                            self.playerService.toggleShuffle()
                        }
                        Task { await self.play(playableTracks, startingAt: 0) }
                    } label: {
                        Label(String(localized: "Shuffle"), systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(playableTracks.isEmpty)
                }
                .padding(.top, 6)
            }
            Spacer()
        }
    }

    private func trackList(_ tracks: [Song]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
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
                .disabled(!track.isPlayable)
                .opacity(track.isPlayable ? 1 : 0.5)
                .onAppear {
                    if index >= tracks.count - 3, self.viewModel.hasMore {
                        Task { await self.viewModel.loadMore() }
                    }
                }
                Divider().opacity(0.2)
            }

            if self.viewModel.loadingState == .loadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                        .padding()
                    Spacer()
                }
            }
        }
    }

    private func playFromIndex(_ index: Int, tracks: [Song]) async {
        guard tracks.indices.contains(index), tracks[index].isPlayable else { return }

        let playableTracks = self.playableTracks(in: tracks)
        let playableIndex = tracks[...index].filter(\.isPlayable).count - 1
        await self.play(playableTracks, startingAt: playableIndex)
    }

    private func play(_ tracks: [Song], startingAt index: Int) async {
        guard tracks.indices.contains(index) else { return }
        await self.playerService.playQueue(tracks, startingAt: index)
    }

    private func playableTracks(in tracks: [Song]) -> [Song] {
        tracks.filter(\.isPlayable)
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

    @State private var lastLoadedVideoId: String?
    @State private var isLoadingFallback = false

    var body: some View {
        CompatGlassContainer(spacing: 0) {
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

                self.contentView
            }
            .frame(width: self.preferredWidth)
            .compatGlass(interactive: true, in: .rect(cornerRadius: 20))
        }
        .onChange(of: self.playerService.currentTrack?.videoId) { _, newVideoId in
            if let videoId = newVideoId, videoId != self.lastLoadedVideoId {
                Task { await self.loadLyrics(for: videoId) }
            }
        }
        .task {
            if let videoId = self.playerService.currentTrack?.videoId {
                await self.loadLyrics(for: videoId)
            }
        }
        .onChange(of: self.syncedLyricsService.currentLyrics) { _, newLyrics in
            self.updateLyricsPolling(for: newLyrics)
        }
        .onDisappear {
            SingletonPlayerWebView.shared.stopLyricsPoll()
        }
        .onAppear {
            self.updateLyricsPolling(for: self.syncedLyricsService.currentLyrics)
        }
        .accessibilityIdentifier(AccessibilityID.Lyrics.fallbackPanel)
    }

    @ViewBuilder
    private var contentView: some View {
        if self.playerService.currentTrack == nil {
            self.noTrackPlayingView
        } else if self.syncedLyricsService.isLoading || self.isLoadingFallback {
            self.loadingView
        } else {
            switch self.syncedLyricsService.currentLyrics {
            case let .synced(synced):
                SyncedLyricsDisplayView(
                    lyrics: synced,
                    currentLineIndex: self.playerService.currentLyricsLineIndex,
                    displayTimeMs: self.playerService.currentLyricsDisplayTimeMs,
                    onSeek: { timeMs in
                        Task { await self.playerService.seek(to: Double(timeMs) / 1000.0) }
                    }
                )
            case let .plain(plain):
                self.plainLyricsContentView(plain)
            case .unavailable:
                self.noLyricsView
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.regular)
                .frame(width: 20, height: 20)
            Text(String(localized: "Loading lyrics..."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func plainLyricsContentView(_ lyrics: Lyrics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(lyrics.text)
                    .font(.system(size: 15, weight: .medium))
                    .lineSpacing(8)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)

                if let source = lyrics.source {
                    Divider()
                        .padding(.horizontal, 16)

                    Text(source)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    private var noLyricsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text(String(localized: "No Lyrics Available"))
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(String(localized: "There aren't any lyrics available for this song."))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noTrackPlayingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.circle")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text(String(localized: "No Song Playing"))
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(String(localized: "Play a song to view its lyrics here."))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func updateLyricsPolling(for result: LyricResult) {
        if case let .synced(synced) = result {
            self.playerService.currentLyricsLineIndex = nil
            self.playerService.currentLyricsDisplayTimeMs = nil
            SingletonPlayerWebView.shared.startLyricsPoll(lineRanges: synced.bridgeLineRanges)
        } else {
            SingletonPlayerWebView.shared.stopLyricsPoll()
            self.playerService.currentLyricsLineIndex = nil
            self.playerService.currentLyricsDisplayTimeMs = nil
        }
    }

    @MainActor
    private func loadLyrics(for videoId: String) async {
        self.lastLoadedVideoId = videoId
        self.isLoadingFallback = false

        guard let track = self.playerService.currentTrack else { return }
        guard track.videoId == videoId else { return }

        let info = LyricsSearchInfo(
            title: track.title,
            artist: track.artistsDisplay,
            album: track.album?.title,
            duration: track.duration,
            videoId: track.videoId
        )

        if SettingsManager.shared.syncedLyricsEnabled {
            await self.syncedLyricsService.fetchLyrics(for: info)
        } else {
            self.syncedLyricsService.currentLyrics = .unavailable
            self.syncedLyricsService.activeProvider = nil
        }

        guard self.lastLoadedVideoId == videoId else { return }
        guard self.playerService.currentTrack?.videoId == videoId else { return }

        if case .unavailable = self.syncedLyricsService.currentLyrics {
            self.isLoadingFallback = true
            defer {
                if self.lastLoadedVideoId == videoId {
                    self.isLoadingFallback = false
                }
            }

            do {
                let fetchedLyrics = try await self.client.getLyrics(videoId: videoId)
                if self.lastLoadedVideoId == videoId,
                   self.playerService.currentTrack?.videoId == videoId
                {
                    self.syncedLyricsService.fallbackToPlainLyrics(fetchedLyrics, videoId: videoId)
                }
            } catch {
                DiagnosticsLogger.api.error("Failed to load plain lyrics fallback: \(error.localizedDescription)")
            }
        }
    }
}
