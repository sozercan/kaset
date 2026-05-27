import SwiftUI

// MARK: - NowPlayingLyricsView

/// Full-screen now-playing surface with album art, playback controls, and lyrics.
@available(macOS 26.0, *)
struct NowPlayingLyricsView: View {
    private static let brandAccent = PackageResourceLookup.brandAccent

    @Environment(PlayerService.self) private var playerService
    @Environment(SyncedLyricsService.self) private var syncedLyricsService

    let client: any YTMusicClientProtocol

    @State private var lastLoadedVideoId: String?
    @State private var isLoadingFallback = false
    @State private var seekValue: Double = 0
    @State private var isSeeking = false
    @State private var volumeValue: Double = 1
    @State private var isAdjustingVolume = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                self.backgroundView

                if let track = self.playerService.currentTrack {
                    self.contentView(track: track, availableSize: geometry.size)
                }
            }
            .ignoresSafeArea()
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .onChange(of: self.playerService.currentTrack?.videoId) { _, newVideoId in
                if let newVideoId {
                    Task { await self.loadLyrics(for: newVideoId) }
                }
            }
            .onChange(of: self.playerService.progress) { _, newValue in
                if !self.isSeeking, self.playerService.duration > 0 {
                    self.seekValue = newValue / self.playerService.duration
                }
            }
            .onChange(of: self.playerService.volume) { _, newValue in
                if !self.isAdjustingVolume {
                    self.volumeValue = newValue
                }
            }
            .task {
                self.volumeValue = self.playerService.volume
                if self.playerService.duration > 0 {
                    self.seekValue = self.playerService.progress / self.playerService.duration
                }
                if let videoId = self.playerService.currentTrack?.videoId {
                    await self.loadLyrics(for: videoId)
                }
            }
        }
    }

    private var backgroundView: some View {
        ZStack {
            if let track = self.playerService.currentTrack {
                CachedAsyncImage(url: track.thumbnailURL, targetSize: .init(width: 900, height: 900)) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 64)
                        .scaleEffect(1.18)
                        .opacity(0.72)
                } placeholder: {
                    Color(nsColor: .windowBackgroundColor)
                }
            }

            LinearGradient(
                colors: [
                    .black.opacity(0.58),
                    .black.opacity(0.28),
                    .black.opacity(0.68),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Color(Self.brandAccent)
                .opacity(0.16)
                .blendMode(.softLight)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            self.close()
        }
    }

    private func contentView(track: Song, availableSize: CGSize) -> some View {
        let metrics = self.layoutMetrics(for: availableSize)

        return VStack(spacing: 0) {
            HStack {
                Spacer()

                Button {
                    self.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.84))
                .help(String(localized: "Close now playing"))
                .accessibilityLabel(String(localized: "Close now playing"))
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.top, metrics.topPadding)

            HStack(spacing: metrics.columnSpacing) {
                VStack(spacing: 0) {
                    Spacer()
                    self.artworkAndControls(track: track, artworkSize: metrics.artworkSize)
                        .frame(width: metrics.artworkColumnWidth)
                    Spacer()
                }
                .frame(maxHeight: .infinity)

                VStack(spacing: 0) {
                    self.lyricsPane(availableSize: availableSize)
                        .frame(maxWidth: metrics.lyricsPaneWidth, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: metrics.lyricsPaneWidth, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, metrics.horizontalPadding + 28)
            .padding(.bottom, metrics.bottomPadding)
        }
        .frame(width: availableSize.width, height: availableSize.height)
    }

    private func artworkAndControls(track: Song, artworkSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            CachedAsyncImage(url: track.thumbnailURL, targetSize: .init(width: 760, height: 760)) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.12))
                    .overlay {
                        CassetteIcon(size: 80)
                            .foregroundStyle(.white.opacity(0.55))
                    }
            }
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.24), radius: 20, y: 10)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(self.subtitle(for: track))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }

                Spacer()

                self.secondaryTrackActions(track: track)
            }

            self.progressControl

            self.transportControls

            self.volumeControl
        }
    }

    private func secondaryTrackActions(track: Song) -> some View {
        HStack(spacing: 10) {
            Button {
                HapticService.toggle()
                self.playerService.toggleLibraryStatus()
            } label: {
                Image(systemName: self.playerService.currentTrackInLibrary ? "star.fill" : "star")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.82))
            .background(.white.opacity(0.16), in: Circle())
            .disabled(self.playerService.currentTrack == nil)
            .accessibilityLabel(self.playerService.currentTrackInLibrary ? String(localized: "Remove from Library") : String(localized: "Add to Library"))

            Menu {
                ShareContextMenu.menuItem(for: track)
                AddToQueueContextMenu(song: track, playerService: self.playerService)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.white.opacity(0.82))
            .background(.white.opacity(0.16), in: Circle())
            .accessibilityLabel(String(localized: "More"))
        }
    }

    private var progressControl: some View {
        VStack(spacing: 4) {
            Slider(value: self.$seekValue, in: 0 ... 1) { editing in
                if editing {
                    self.isSeeking = true
                } else {
                    self.performSeek()
                }
            }
            .controlSize(.small)
            .tint(.white)

            HStack {
                Text(self.formatTime(self.isSeeking ? self.seekValue * self.playerService.duration : self.playerService.progress))
                Spacer()
                Text("-\(self.formatTime(self.playerService.duration - self.seekValue * self.playerService.duration))")
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.52))
        }
    }

    private var transportControls: some View {
        HStack(spacing: 28) {
            Button {
                HapticService.toggle()
                self.playerService.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(self.playerService.shuffleEnabled ? Self.brandAccent : .white.opacity(0.78))
            }
            .buttonStyle(.plain)

            Button {
                HapticService.playback()
                Task { await self.playerService.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 24, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(self.playerService.currentEpisode != nil)

            Button {
                HapticService.playback()
                Task { await self.playerService.playPause() }
            } label: {
                Image(systemName: self.playerService.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            Button {
                HapticService.playback()
                Task { await self.playerService.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 24, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(self.playerService.currentEpisode != nil)

            Button {
                HapticService.toggle()
                self.playerService.cycleRepeatMode()
            } label: {
                Image(systemName: self.repeatIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(self.playerService.repeatMode == .off ? .white.opacity(0.78) : Self.brandAccent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
    }

    private var volumeControl: some View {
        HStack(spacing: 10) {
            Image(systemName: self.volumeIcon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18)

            Slider(value: self.$volumeValue, in: 0 ... 1) { editing in
                if editing {
                    self.isAdjustingVolume = true
                } else {
                    self.isAdjustingVolume = false
                    Task { await self.playerService.setVolume(self.volumeValue) }
                }
            }
            .controlSize(.small)
            .tint(.white)
            .onChange(of: self.volumeValue) { _, newValue in
                guard self.isAdjustingVolume else { return }
                Task { await self.playerService.setVolume(newValue) }
            }
        }
        .foregroundStyle(.white.opacity(0.78))
    }

    @ViewBuilder
    private func lyricsPane(availableSize: CGSize) -> some View {
        if self.syncedLyricsService.isLoading || self.isLoadingFallback {
            ProgressView()
                .controlSize(.regular)
                .tint(.white)
        } else {
            switch self.syncedLyricsService.currentLyrics {
            case let .synced(synced):
                SyncedLyricsDisplayView(
                    lyrics: synced,
                    currentTimeMs: self.playerService.currentTimeMs,
                    autoScrolls: false,
                    verticalContentInset: self.lyricsEdgeInset(for: availableSize.height),
                    onSeek: { timeMs in
                        Task { await self.playerService.seek(to: Double(timeMs) / 1000) }
                    }
                )
            case let .plain(lyrics):
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer(minLength: self.lyricsEdgeInset(for: availableSize.height))

                        Text(lyrics.text)
                            .font(.system(size: 24, weight: .bold))
                            .lineSpacing(16)
                            .foregroundStyle(.white.opacity(0.82))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Spacer(minLength: self.lyricsEdgeInset(for: availableSize.height))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            case .unavailable:
                VStack(spacing: 10) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 34, weight: .semibold))
                    Text("No Lyrics Available")
                        .font(.system(size: 22, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.58))
            }
        }
    }

    @MainActor
    private func loadLyrics(for videoId: String) async {
        self.lastLoadedVideoId = videoId
        self.isLoadingFallback = false

        guard let track = self.playerService.currentTrack,
              track.videoId == videoId
        else {
            return
        }

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

        guard self.lastLoadedVideoId == videoId,
              self.playerService.currentTrack?.videoId == videoId,
              case .unavailable = self.syncedLyricsService.currentLyrics
        else {
            return
        }

        self.isLoadingFallback = true
        defer {
            if self.lastLoadedVideoId == videoId {
                self.isLoadingFallback = false
            }
        }

        do {
            let fetchedLyrics = try await self.client.getLyrics(videoId: videoId)
            guard self.lastLoadedVideoId == videoId,
                  self.playerService.currentTrack?.videoId == videoId
            else {
                return
            }

            self.syncedLyricsService.fallbackToPlainLyrics(fetchedLyrics, videoId: videoId)
        } catch {
            DiagnosticsLogger.api.error("Failed to load full now-playing lyrics fallback: \(error.localizedDescription)")
        }
    }

    private func performSeek() {
        guard self.isSeeking else { return }
        let seekTime = self.seekValue * self.playerService.duration
        Task {
            await self.playerService.seek(to: seekTime)
            self.isSeeking = false
        }
    }

    private func close() {
        withAnimation(AppAnimation.standard) {
            self.playerService.showNowPlayingLyrics = false
        }
    }

    private func layoutMetrics(for size: CGSize) -> LayoutMetrics {
        LayoutMetrics(
            topPadding: max(16, min(size.height * 0.03, 28)),
            horizontalPadding: max(28, min(size.width * 0.06, 76)),
            bottomPadding: max(18, min(size.height * 0.04, 40)),
            columnSpacing: max(36, min(size.height * 0.08, 64)),
            artworkSize: max(240, min(size.height * 0.38, 360)),
            artworkColumnWidth: max(300, min(size.height * 0.40, 400)),
            lyricsPaneWidth: max(360, min(size.width * 0.40, 560))
        )
    }

    private func lyricsEdgeInset(for height: CGFloat) -> CGFloat {
        max(8, min(height * 0.028, 28))
    }

    private func subtitle(for track: Song) -> String {
        if let album = track.album?.title, !album.isEmpty {
            "\(track.artistsDisplay) - \(album)"
        } else {
            track.artistsDisplay
        }
    }

    private var repeatIcon: String {
        switch self.playerService.repeatMode {
        case .off, .all:
            "repeat"
        case .one:
            "repeat.1"
        }
    }

    private var volumeIcon: String {
        let volume = self.isAdjustingVolume ? self.volumeValue : self.playerService.volume
        if volume == 0 {
            return "speaker.slash.fill"
        } else if volume < 0.5 {
            return "speaker.wave.1.fill"
        } else {
            return "speaker.wave.2.fill"
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    private struct LayoutMetrics {
        let topPadding: CGFloat
        let horizontalPadding: CGFloat
        let bottomPadding: CGFloat
        let columnSpacing: CGFloat
        let artworkSize: CGFloat
        let artworkColumnWidth: CGFloat
        let lyricsPaneWidth: CGFloat
    }
}
