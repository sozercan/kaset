import SwiftUI

// MARK: - FullScreenPlayerView

/// Now-playing view that covers the main window, laid out like Apple Music's full screen
/// player: artwork, track info and transport controls on the left, lyrics or the queue on
/// the right, over a blurred copy of the artwork. Closing it reveals the untouched window below.
struct FullScreenPlayerView: View {
    /// Content shown beside the player column.
    enum SidePane {
        case lyrics
        case queue
    }

    @Environment(PlayerService.self) private var playerService
    @Environment(AuthService.self) private var authService
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI
    @State private var seekState = MiniPlayerSeekState()
    @State private var sidePane: SidePane? = .lyrics

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            ZStack {
                self.backdrop

                HStack(spacing: 0) {
                    let columnWidth = self.sidePane == nil ? size.width : size.width / 2
                    let artworkSize = Self.artworkSize(for: size, columnWidth: columnWidth)

                    self.playerColumn(artworkSize: artworkSize)
                        .frame(width: columnWidth)
                        .frame(maxHeight: .infinity)

                    if let sidePane = self.sidePane {
                        self.sidePaneView(sidePane)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, 56)
                            .padding(.bottom, 56)
                            .padding(.trailing, 48)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .overlay(alignment: .topLeading) { self.windowControls }
            .overlay(alignment: .topTrailing) {
                NowPlayingVolumeControl()
                    .padding(Self.chromeInset)
            }
            .overlay(alignment: .bottomTrailing) {
                self.sidePaneToggles
                    .padding(Self.chromeInset)
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(AppAnimation.standard, value: self.sidePane)
    }

    // MARK: - Layout

    /// Inset of the glass capsules from the window edges; it lines the top capsules up with
    /// the traffic lights.
    private static let chromeInset: CGFloat = 8

    /// Leading offset of the close capsule, just past the traffic lights.
    private static let windowControlsLeading: CGFloat = 78

    static func artworkSize(for size: CGSize, columnWidth: CGFloat) -> CGFloat {
        // Leave room below the artwork for title, seek bar and controls.
        let byHeight = size.height - 330
        let byWidth = columnWidth - 120
        return max(180, min(byHeight, byWidth, 560))
    }

    // MARK: - Views

    private var backdrop: some View {
        ZStack {
            Color.black

            if let track = self.playerService.currentTrack {
                SongThumbnailView(song: track, size: 320, cornerRadius: 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(1.8)
                    .blur(radius: 90)
                    .opacity(0.85)
                    .clipped()
            }

            Color.black.opacity(0.25)
        }
        .ignoresSafeArea()
        .overlay { WindowDragHandle() }
    }

    private func playerColumn(artworkSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            self.artwork(size: artworkSize)

            self.trackInfo(fontSize: max(14, min(20, artworkSize * 0.05)))
                .padding(.top, 16)

            Group {
                if self.playerService.isShowingAd {
                    // The indicator bottom-aligns in a 30 pt frame; lift it onto the seek bar's line.
                    PlayerBarAdIndicator()
                        .padding(.top, -14)
                } else {
                    MiniPlayerSeekSection(state: self.seekState, style: .nowPlaying)
                }
            }
            // Same height for both, so the controls below don't jump when an ad starts.
            .frame(height: 36, alignment: .top)
            .padding(.top, 18)

            self.transportControls
                .padding(.top, 14)
        }
        .frame(width: artworkSize)
    }

    private func artwork(size: CGFloat) -> some View {
        Group {
            if let track = self.playerService.currentTrack {
                SongThumbnailView(song: track, size: size, cornerRadius: 10)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.12))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.32, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(width: size, height: size)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
    }

    private func trackInfo(fontSize: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.playerService.currentTrack?.title ?? String(localized: "Not Playing"))
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                // Closes the full screen view and lets the visible player bar open the artist page.
                Button(action: self.openArtist) {
                    Text(self.subtitle)
                        .font(.system(size: fontSize))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(self.playerService.currentTrack == nil)
                .pointerStyle(.link)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let track = self.playerService.currentTrack {
                if self.authService.hasPersonalAccount {
                    self.circleButton(
                        systemName: self.playerService.currentTrackLikeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup",
                        label: String(localized: "Like"),
                        accessibilityValue: Self.likeAccessibilityValue(for: self.playerService.currentTrackLikeStatus)
                    ) {
                        HapticService.toggle()
                        self.playerService.likeCurrentTrack()
                    }
                }

                Menu {
                    self.moreMenu(for: track)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.14), in: .circle)
                        .contentShape(.circle)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(String(localized: "More"))
                .accessibilityLabel(String(localized: "More"))
            }
        }
    }

    private func moreMenu(for track: Song) -> some View {
        SongContextMenu(
            song: track,
            client: self.playerService.ytMusicClient,
            libraryToggle: SongLibraryToggle(
                isInLibrary: self.playerService.currentTrackInLibrary,
                toggle: { self.playerService.toggleLibraryStatus() }
            ),
            // The overlay has no navigation stack: artist pages go through the player bar,
            // and albums have no such route.
            showsGoToArtist: true,
            showsGoToAlbum: false,
            navigate: { destination in
                if destination is Artist {
                    self.openArtist()
                }
            }
        )
    }

    private var transportControls: some View {
        HStack(spacing: 0) {
            self.controlButton(
                systemName: "shuffle",
                size: 15,
                isActive: self.playerService.shuffleEnabled,
                label: String(localized: "Shuffle"),
                accessibilityValue: Self.shuffleAccessibilityValue(for: self.playerService.shuffleMode)
            ) {
                // Same cycle as the player bar, so Smart Shuffle stays reachable here.
                HapticService.toggle()
                self.playerService.cycleShuffleMode()
            }

            Spacer(minLength: 8)

            self.controlButton(systemName: "backward.fill", size: 24, label: String(localized: "Previous track")) {
                Task { await self.playerService.previous() }
            }
            .disabled(self.playerService.currentEpisode != nil)

            Spacer(minLength: 8)

            self.controlButton(
                systemName: self.playerService.isPlaying ? "pause.fill" : "play.fill",
                size: 32,
                label: self.playerService.isPlaying ? String(localized: "Pause") : String(localized: "Play")
            ) {
                Task { await self.playerService.playPause() }
            }
            .contentTransition(.symbolEffect(.replace))

            Spacer(minLength: 8)

            self.controlButton(systemName: "forward.fill", size: 24, label: String(localized: "Next track")) {
                Task { await self.playerService.next() }
            }
            .disabled(self.playerService.currentEpisode != nil)

            Spacer(minLength: 8)

            self.controlButton(
                systemName: self.playerService.repeatMode == .one ? "repeat.1" : "repeat",
                size: 15,
                isActive: self.playerService.repeatMode != .off,
                label: String(localized: "Repeat"),
                accessibilityValue: Self.repeatAccessibilityValue(for: self.playerService.repeatMode)
            ) {
                self.playerService.cycleRepeatMode()
            }
        }
    }

    @ViewBuilder
    private func sidePaneView(_ pane: SidePane) -> some View {
        switch pane {
        case .lyrics:
            if let client = self.playerService.ytMusicClient {
                if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
                    LyricsView(client: client, showsHeader: false, preferredWidth: nil, showsPanel: false)
                } else {
                    SimpleLyricsView(client: client, showsHeader: false, preferredWidth: nil, showsPanel: false)
                }
            }
        case .queue:
            NowPlayingQueueView()
        }
    }

    /// Close and mini player buttons, just past the traffic lights.
    private var windowControls: some View {
        HStack(spacing: 2) {
            NowPlayingGlassIconButton(systemName: "xmark", label: String(localized: "Close"), action: self.close)
                .keyboardShortcut(.cancelAction)

            NowPlayingGlassIconButton(
                systemName: "rectangle.inset.bottomright.filled",
                label: String(localized: "Switch to Mini Player")
            ) {
                HapticService.toggle()
                self.close()
                _ = self.playerService.toggleMiniPlayer(mode: .switchFromMainWindow)
            }
        }
        .padding(.horizontal, 2)
        .compatGlass(interactive: true, in: .capsule)
        .padding(.leading, Self.windowControlsLeading)
        .padding(.top, Self.chromeInset)
    }

    private var sidePaneToggles: some View {
        HStack(spacing: 2) {
            self.sidePaneToggle(.lyrics, systemName: "quote.bubble", selectedSystemName: "quote.bubble.fill", label: String(localized: "Lyrics"))
            self.sidePaneToggle(.queue, systemName: "list.bullet", selectedSystemName: "list.bullet", label: String(localized: "Queue"))
        }
        .padding(.horizontal, 2)
        .compatGlass(interactive: true, in: .capsule)
    }

    private func sidePaneToggle(_ pane: SidePane, systemName: String, selectedSystemName: String, label: String) -> some View {
        let isSelected = self.sidePane == pane
        return NowPlayingGlassIconButton(
            systemName: isSelected ? selectedSystemName : systemName,
            label: label,
            isSelected: isSelected,
            accessibilityValue: isSelected ? String(localized: "Showing") : String(localized: "Hidden")
        ) {
            HapticService.toggle()
            self.sidePane = isSelected ? nil : pane
        }
    }

    private func circleButton(
        systemName: String,
        label: String,
        accessibilityValue: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.14), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    private func controlButton(
        systemName: String,
        size: CGFloat,
        isActive: Bool = false,
        label: String,
        accessibilityValue: String = "",
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isActive ? PackageResourceLookup.brandAccent : .white.opacity(0.92))
                .frame(minWidth: 36, minHeight: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    // MARK: - Helpers

    static func shuffleAccessibilityValue(for mode: PlayerService.ShuffleMode) -> String {
        switch mode {
        case .off: String(localized: "Off")
        case .on: String(localized: "On")
        case .smart: String(localized: "Smart")
        }
    }

    static func repeatAccessibilityValue(for mode: PlayerService.RepeatMode) -> String {
        switch mode {
        case .off: String(localized: "Off")
        case .all: String(localized: "All")
        case .one: String(localized: "One")
        }
    }

    static func likeAccessibilityValue(for status: LikeStatus) -> String {
        status == .like ? String(localized: "Liked") : String(localized: "Not liked")
    }

    /// "Artist — Album", or just the artist when the album is unknown.
    static func subtitle(for track: Song) -> String {
        let artist = track.artistsDisplay.isEmpty ? String(localized: "Unknown Artist") : track.artistsDisplay
        guard let album = track.album?.title, !album.isEmpty else { return artist }
        return "\(artist) — \(album)"
    }

    private var subtitle: String {
        guard let track = self.playerService.currentTrack else { return "" }
        return Self.subtitle(for: track)
    }

    private func openArtist() {
        self.close()
        self.playerService.requestArtistNavigation()
    }

    private func close() {
        withAnimation(AppAnimation.standard) {
            self.playerService.showFullScreenPlayer = false
        }
    }
}
