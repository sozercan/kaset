import SwiftUI

// MARK: - ExpandedPlayerView

/// Apple Music-style expanded "Now Playing" view covering the main window.
/// Opened by clicking the track info in the bottom player bar; shows large
/// album art, track metadata, full transport controls, and a toggleable
/// queue panel on the right.
struct ExpandedPlayerView: View {
    private static let brandAccent = PackageResourceLookup.brandAccent
    private static let queuePanelWidth: CGFloat = 320
    private static let maxArtworkSide: CGFloat = 420

    /// Invoked when the artist name is clicked, to navigate to the artist's page.
    var onNavigateToArtist: (Artist) -> Void = { _ in }

    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager

    /// Whether the queue panel on the right is visible.
    @State private var showQueuePanel = true

    /// Whether the pointer is hovering the (clickable) artist name.
    @State private var isHoveringArtist = false

    /// Local seek value for smooth slider dragging without network calls on every change.
    @State private var seekValue: Double = 0
    @State private var isSeeking = false

    /// Local volume value for smooth slider dragging.
    @State private var volumeValue: Double = 1.0
    @State private var isAdjustingVolume = false

    /// Tracks a failed primary artwork load so the YouTube fallback is used.
    @State private var failedArtworkKey: SongThumbnailSource.PrimaryFailureKey?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .accentBackground(from: self.playerService.currentTrack?.largeThumbnailURL)

            HStack(spacing: 24) {
                self.nowPlayingColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if self.showQueuePanel {
                    self.queuePanel
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(24)

            self.closeButton
                .padding(20)
        }
        // The window-level Escape shortcut lives at the MainWindow mount so it
        // can yield to the command bar; this handles the focused-view path.
        .onExitCommand {
            self.close()
        }
        .onChange(of: self.playerService.currentTrack) { _, newTrack in
            if newTrack == nil {
                self.close()
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
        .onAppear {
            self.volumeValue = self.playerService.volume
            if self.playerService.duration > 0 {
                self.seekValue = self.playerService.progress / self.playerService.duration
            }
        }
        .accessibilityIdentifier(AccessibilityID.ExpandedPlayer.container)
    }

    private func close() {
        withAnimation(AppAnimation.smooth) {
            self.playerService.showExpandedPlayer = false
        }
    }

    // MARK: - Close Button

    private var closeButton: some View {
        Button {
            HapticService.toggle()
            self.close()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .compatGlass(interactive: true, in: .circle)
        .accessibilityIdentifier(AccessibilityID.ExpandedPlayer.closeButton)
        .accessibilityLabel(String(localized: "Close Now Playing"))
        .help(String(localized: "Close Now Playing"))
    }

    // MARK: - Now Playing Column

    private var nowPlayingColumn: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            self.artworkView

            self.trackInfo

            self.seekSection
                .frame(maxWidth: Self.maxArtworkSide)

            self.transportControls

            self.volumeRow

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }

    private var artworkSource: SongThumbnailSource? {
        guard let track = self.playerService.currentTrack else { return nil }
        return SongThumbnailSource(
            videoId: track.videoId,
            primaryURL: track.largeThumbnailURL,
            fallbackURL: track.fallbackThumbnailURL
        )
    }

    private var artworkView: some View {
        GeometryReader { proxy in
            let side = min(min(proxy.size.width, proxy.size.height), Self.maxArtworkSide)

            ZStack {
                if let source = self.artworkSource {
                    CachedAsyncImage(
                        url: source.activeURL(failedPrimaryKey: self.failedArtworkKey),
                        // Matches the 544px source resolution from largeThumbnailURL.
                        targetSize: CGSize(width: 544, height: 544),
                        onFailure: self.artworkFailureHandler(for: source)
                    ) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        self.artworkPlaceholder
                    }
                } else {
                    self.artworkPlaceholder
                }
            }
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: 12))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
            .scaleEffect(self.playerService.isPlaying ? 1.0 : 0.92)
            .animation(AppAnimation.spring, value: self.playerService.isPlaying)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: Self.maxArtworkSide)
        .accessibilityIdentifier(AccessibilityID.ExpandedPlayer.artwork)
        .accessibilityHidden(true)
    }

    private var artworkPlaceholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                CassetteIcon(size: 60)
                    .foregroundStyle(.secondary)
            }
    }

    private func artworkFailureHandler(for source: SongThumbnailSource) -> (@MainActor () -> Void)? {
        guard source.activeURL(failedPrimaryKey: self.failedArtworkKey) == source.primaryURL,
              let primaryFailureKey = source.primaryFailureKey
        else {
            return nil
        }

        return {
            self.failedArtworkKey = primaryFailureKey
        }
    }

    private var trackInfo: some View {
        VStack(spacing: 4) {
            Text(self.playerService.currentTrack?.title ?? String(localized: "Not Playing"))
                .font(.title2.bold())
                .lineLimit(1)
                .foregroundStyle(.primary)
                .accessibilityIdentifier(AccessibilityID.ExpandedPlayer.trackTitle)

            self.artistLabel
        }
        .frame(maxWidth: Self.maxArtworkSide)
        .contextMenu {
            if let track = self.playerService.currentTrack {
                FavoritesContextMenu.menuItem(for: track, manager: self.favoritesManager)

                Divider()

                StartRadioContextMenu.menuItem(for: track, playerService: self.playerService)

                Divider()

                ShareContextMenu.menuItem(for: track)
            }
        }
    }

    private var artistDisplay: String {
        guard let track = self.playerService.currentTrack else { return "" }
        return track.artistsDisplay.isEmpty ? String(localized: "Unknown Artist") : track.artistsDisplay
    }

    /// The first artist that has a navigable page, if any.
    private var navigableArtist: Artist? {
        self.playerService.currentTrack?.artists.first(where: { $0.hasNavigableId })
    }

    /// Artist name — a clickable link when the artist has a navigable page,
    /// otherwise plain text.
    @ViewBuilder
    private var artistLabel: some View {
        if let artist = self.navigableArtist {
            Button {
                self.onNavigateToArtist(artist)
            } label: {
                Text(self.artistDisplay)
                    .font(.title3)
                    .lineLimit(1)
                    .foregroundStyle(self.isHoveringArtist ? Self.brandAccent : Color.secondary)
                    .underline(self.isHoveringArtist)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    self.isHoveringArtist = hovering
                }
            }
            .accessibilityIdentifier(AccessibilityID.ExpandedPlayer.trackArtist)
            .accessibilityLabel(String(localized: "Go to artist \(self.artistDisplay)"))
            .accessibilityAddTraits(.isLink)
        } else {
            Text(self.artistDisplay)
                .font(.title3)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.ExpandedPlayer.trackArtist)
        }
    }

    // MARK: - Seek Section

    private var seekSection: some View {
        VStack(spacing: 6) {
            Slider(value: self.$seekValue, in: 0 ... 1) { editing in
                if editing {
                    self.isSeeking = true
                } else {
                    self.performSeek()
                }
            }
            .controlSize(.small)
            .tint(Self.brandAccent)
            .disabled(self.playerService.duration <= 0 || self.playerService.isCurrentItemLive)
            .accessibilityIdentifier(AccessibilityID.ExpandedPlayer.seekSlider)

            HStack {
                Text(self.elapsedTimeText)

                Spacer()

                if self.playerService.isCurrentItemLive {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 7, height: 7)
                        Text("LIVE", comment: "Label shown in the expanded player when playing a live radio stream")
                            .foregroundStyle(.red)
                    }
                } else {
                    Text(self.remainingTimeText)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    /// Elapsed playback time, tracking the slider position while seeking.
    private var currentElapsed: TimeInterval {
        self.isSeeking ? self.seekValue * self.playerService.duration : self.playerService.progress
    }

    private var elapsedTimeText: String {
        self.currentElapsed.formattedDuration
    }

    private var remainingTimeText: String {
        "-\(max(0, self.playerService.duration - self.currentElapsed).formattedDuration)"
    }

    /// Performs the actual seek operation after slider interaction ends.
    private func performSeek() {
        guard self.isSeeking else { return }
        let seekTime = self.seekValue * self.playerService.duration
        Task {
            await self.playerService.seek(to: seekTime)
            self.isSeeking = false
        }
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack(spacing: 28) {
            // Shuffle
            Button {
                HapticService.toggle()
                self.playerService.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(self.playerService.shuffleEnabled ? .red : .primary.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier(AccessibilityID.ExpandedPlayer.shuffleButton)
            .accessibilityLabel(String(localized: "Shuffle"))
            .accessibilityValue(self.playerService.shuffleEnabled ? String(localized: "On") : String(localized: "Off"))

            // Previous
            Button {
                HapticService.playback()
                Task {
                    await self.playerService.previous()
                }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.pressable)
            .disabled(self.playerService.currentEpisode != nil)
            .accessibilityIdentifier(AccessibilityID.ExpandedPlayer.previousButton)
            .accessibilityLabel(String(localized: "Previous track"))

            // Play/Pause
            Button {
                HapticService.playback()
                Task {
                    await self.playerService.playPause()
                }
            } label: {
                Image(systemName: self.playerService.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.primary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier(AccessibilityID.ExpandedPlayer.playPauseButton)
            .accessibilityLabel(self.playerService.isPlaying ? String(localized: "Pause") : String(localized: "Play"))

            // Next
            Button {
                HapticService.playback()
                Task {
                    await self.playerService.next()
                }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.pressable)
            .disabled(self.playerService.currentEpisode != nil)
            .accessibilityIdentifier(AccessibilityID.ExpandedPlayer.nextButton)
            .accessibilityLabel(String(localized: "Next track"))

            // Repeat
            Button {
                HapticService.toggle()
                self.playerService.cycleRepeatMode()
            } label: {
                Image(systemName: self.repeatIcon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(self.playerService.repeatMode != .off ? .red : .primary.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier(AccessibilityID.ExpandedPlayer.repeatButton)
            .accessibilityLabel(String(localized: "Repeat"))
            .accessibilityValue(self.repeatAccessibilityValue)
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

    private var repeatAccessibilityValue: String {
        switch self.playerService.repeatMode {
        case .off:
            String(localized: "Off")
        case .all:
            String(localized: "All")
        case .one:
            String(localized: "One")
        }
    }

    // MARK: - Volume Row

    private var volumeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: self.volumeIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Slider(value: self.$volumeValue, in: 0 ... 1) { editing in
                if editing {
                    self.isAdjustingVolume = true
                } else {
                    self.isAdjustingVolume = false
                    // Always apply volume when interaction ends to ensure WebView is synced
                    Task {
                        await self.playerService.setVolume(self.volumeValue)
                    }
                }
            }
            .frame(width: 200)
            .controlSize(.small)
            .tint(Self.brandAccent)
            .accessibilityIdentifier(AccessibilityID.ExpandedPlayer.volumeSlider)
            .onChange(of: self.volumeValue) { oldValue, newValue in
                // Apply volume changes in real-time during dragging for immediate feedback
                if self.isAdjustingVolume {
                    if (oldValue > 0 && newValue == 0) || (oldValue < 1 && newValue == 1) {
                        HapticService.sliderBoundary()
                    }
                    Task {
                        await self.playerService.setVolume(newValue)
                    }
                }
            }

            // Queue panel toggle
            Button {
                HapticService.toggle()
                withAnimation(AppAnimation.standard) {
                    self.showQueuePanel.toggle()
                }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(self.showQueuePanel ? .red : .primary.opacity(0.85))
            }
            .buttonStyle(.pressable)
            .padding(.leading, 8)
            .accessibilityIdentifier(AccessibilityID.ExpandedPlayer.queueToggleButton)
            .accessibilityLabel(String(localized: "Queue"))
            .accessibilityValue(self.showQueuePanel ? String(localized: "Showing") : String(localized: "Hidden"))
        }
    }

    private var volumeIcon: String {
        let currentVolume = self.isAdjustingVolume ? self.volumeValue : self.playerService.volume
        if currentVolume == 0 {
            return "speaker.slash.fill"
        } else if currentVolume < 0.5 {
            return "speaker.wave.1.fill"
        } else {
            return "speaker.wave.2.fill"
        }
    }

    // MARK: - Queue Panel

    private var queuePanel: some View {
        CompatGlassContainer(spacing: 0) {
            VStack(spacing: 0) {
                self.queueHeader

                Divider()
                    .opacity(0.3)

                if self.playerService.queue.isEmpty {
                    self.emptyQueueView
                } else {
                    self.queueListView
                }
            }
            .frame(width: Self.queuePanelWidth)
            .compatGlass(interactive: true, in: .rect(cornerRadius: 20))
        }
        .accessibilityIdentifier(AccessibilityID.ExpandedPlayer.queuePanel)
    }

    private var queueHeader: some View {
        HStack {
            Text("Up Next")
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            // Clear queue button (only show if there are items beyond the current track)
            if self.playerService.queue.count > 1 {
                Button {
                    self.playerService.clearQueue()
                } label: {
                    Text("Clear")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.ExpandedPlayer.queueClearButton)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var emptyQueueView: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text("No Queue")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Play songs from a playlist or album to build your queue.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queueListView: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(self.playerService.queueEntries.enumerated()), id: \.element.id) { index, entry in
                        QueueRowView(
                            song: entry.song,
                            isCurrentTrack: index == self.playerService.currentIndex,
                            index: index,
                            favoritesManager: self.favoritesManager,
                            playerService: self.playerService,
                            onRemove: {
                                self.playerService.removeFromQueue(entryIDs: Set([entry.id]))
                            },
                            onTap: {
                                Task {
                                    await self.playerService.playFromQueue(at: index)
                                }
                            }
                        )
                        .id(index)
                        .accessibilityIdentifier(AccessibilityID.ExpandedPlayer.queueRow(index: index))
                    }
                }
                .padding(.vertical, 8)
            }
            .task(id: self.playerService.currentIndex) {
                scrollProxy.scrollTo(self.playerService.currentIndex, anchor: .center)
            }
        }
    }
}

#Preview {
    ExpandedPlayerView()
        .environment(PlayerService())
        .environment(FavoritesManager.shared)
        .frame(width: 1100, height: 700)
}
