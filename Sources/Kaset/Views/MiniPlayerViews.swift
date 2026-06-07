import AppKit
import SwiftUI

// MARK: - PersistentPlayerView

/// A SwiftUI anchor for the singleton WebView.
/// The WebView is created once, kept attached while audio playback is pending,
/// and normally rendered as a hidden 1×1 view.
struct PersistentPlayerView: NSViewRepresentable {
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(PlayerService.self) private var playerService

    let videoId: String
    let isExpanded: Bool // Retained for compatibility; audio playback keeps this hidden.

    private let logger = DiagnosticsLogger.player

    func makeNSView(context _: Context) -> NSView {
        self.logger.info("PersistentPlayerView.makeNSView for videoId: \(self.videoId)")

        let container = NSView(frame: .zero)
        container.wantsLayer = true

        // Get or create the singleton WebView
        let webView = SingletonPlayerWebView.shared.getWebView(
            webKitManager: self.webKitManager,
            playerService: self.playerService
        )

        // Remove from any previous superview and add to this container
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        // Restored sessions keep the hidden WebView inert until the user explicitly resumes.
        if self.playerService.shouldAutoloadPendingVideo,
           SingletonPlayerWebView.shared.currentVideoId != self.videoId
        {
            self.logger.info("Initial hidden load for videoId: \(self.videoId)")
            SingletonPlayerWebView.shared.loadVideo(videoId: self.videoId)
        }

        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        // Ensure WebView is in this container
        let webView = SingletonPlayerWebView.shared.getWebView(
            webKitManager: self.webKitManager,
            playerService: self.playerService
        )

        if webView.superview !== container {
            self.logger.info("Re-parenting WebView to current container")
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }

        webView.frame = container.bounds

        if self.playerService.shouldAutoloadPendingVideo,
           SingletonPlayerWebView.shared.currentVideoId != self.videoId
        {
            SingletonPlayerWebView.shared.loadVideo(videoId: self.videoId)
        }
    }
}

// MARK: - MiniPlayerToast

/// A small toast-style view that appears when mini player is shown.
/// Uses Liquid Glass materialize transition for smooth appearance.
struct MiniPlayerToast: View {
    let videoId: String

    var body: some View {
        PersistentPlayerView(videoId: self.videoId, isExpanded: true)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .compatGlassTransition(.materialize)
    }
}

// MARK: - MiniPlayerWindow

struct MiniPlayerWindow: View {
    private enum Layout {
        static let chromeTopInset: CGFloat = 12
        static let trafficLightSize: CGFloat = 13
        static let contentChromeGap: CGFloat = 20
        static let headerTopInset = Self.chromeTopInset + Self.trafficLightSize + Self.contentChromeGap
    }

    private enum DetailPane {
        case lyrics
        case queue
    }

    @Environment(PlayerService.self) private var playerService

    let client: any YTMusicClientProtocol

    @State private var settings = SettingsManager.shared
    @State private var seekValue: Double = 0
    @State private var isSeeking = false
    @State private var volumeValue: Double = 1
    @State private var isAdjustingVolume = false
    @State private var detailPane: DetailPane = .lyrics
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .top) {
            self.surface

            self.panelBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            self.hoverChrome
        }
        .environment(\.usesLegacyMacOS15UI, self.settings.useLegacyMacOS15UI)
        .contentShape(.rect)
        .onHover { hovering in
            self.isHovering = hovering
        }
        .clipShape(.rect(cornerRadius: self.cornerRadius))
        .accessibilityIdentifier(AccessibilityID.MiniPlayer.container)
        .onChange(of: self.playerService.progress) { _, newValue in
            if !self.isSeeking, self.playerService.duration > 0 {
                self.seekValue = newValue / self.playerService.duration
            }
        }
        .onChange(of: self.playerService.duration) { _, _ in
            if !self.isSeeking {
                self.syncSeekValue()
            }
        }
        .onChange(of: self.playerService.volume) { _, newValue in
            if !self.isAdjustingVolume {
                self.volumeValue = newValue
            }
        }
        .onAppear {
            self.volumeValue = self.playerService.volume
            self.syncSeekValue()
        }
    }

    private var cornerRadius: CGFloat {
        switch self.playerService.miniPlayerPanel {
        case .compact:
            18
        case .expanded, .lyrics:
            22
        }
    }

    private var surface: some View {
        RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
            .fill(.black.opacity(self.playerService.miniPlayerPanel == .expanded ? 0.76 : 0.50))
            .compatGlass(interactive: true, in: .rect(cornerRadius: self.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.20), lineWidth: 1)
            }
            .overlay {
                LinearGradient(
                    colors: [
                        .white.opacity(0.12),
                        .clear,
                        .black.opacity(0.18),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(.rect(cornerRadius: self.cornerRadius))
                .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.34),
                                .white.opacity(0.06),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            }
    }

    @ViewBuilder
    private var panelBody: some View {
        switch self.playerService.miniPlayerPanel {
        case .compact:
            self.compactBody
        case .expanded:
            self.squareArtworkBody
        case .lyrics:
            self.lyricsBody
        }
    }

    private var hoverChrome: some View {
        HStack(alignment: .center, spacing: 12) {
            self.trafficLights
            Spacer()
            self.hoverCommandPill
                .opacity(self.showsCommandPill ? 1 : 0)
                .blur(radius: self.showsCommandPill ? 0 : 5)
                .scaleEffect(self.showsCommandPill ? 1 : 0.96, anchor: .topTrailing)
                .animation(AppAnimation.snappy, value: self.showsCommandPill)
        }
        .padding(.top, Self.Layout.chromeTopInset)
        .padding(.horizontal, 16)
    }

    private var compactBody: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                self.artwork(size: 42, cornerRadius: 6)

                VStack(alignment: .leading, spacing: 2) {
                    self.titleText
                        .font(.system(size: 13, weight: .semibold))
                    self.artistText
                        .font(.system(size: 10, weight: .medium))
                        .opacity(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                self.hoverOnly {
                    self.trackActionButtons
                }
            }

            self.seekSection
            self.transportControls(playSize: 25, sideSize: 16, spacing: 30)
        }
        .padding(.top, Self.Layout.headerTopInset)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var squareArtworkBody: some View {
        ZStack(alignment: .bottom) {
            self.fullFrameArtwork
            self.squareArtworkTopBackdrop

            self.hoverOnly {
                self.squareArtworkControlBackdrop
            }

            VStack(spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        self.titleText
                            .font(.system(size: 13, weight: .bold))
                        self.artistText
                            .font(.system(size: 10, weight: .medium))
                            .opacity(0.76)
                    }
                    Spacer()
                    self.hoverOnly {
                        self.trackActionButtons
                    }
                }

                self.seekSection
                self.transportControls(playSize: 27, sideSize: 17, spacing: 30)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .shadow(color: .black.opacity(0.82), radius: 3, y: 1)
            .opacity(self.isHovering ? 1 : 0)
            .animation(AppAnimation.quick, value: self.isHovering)
        }
    }

    private var lyricsBody: some View {
        VStack(spacing: 0) {
            VStack(spacing: 7) {
                HStack(spacing: 10) {
                    self.artwork(size: 42, cornerRadius: 6)

                    VStack(alignment: .leading, spacing: 2) {
                        self.titleText
                            .font(.system(size: 13, weight: .semibold))
                        self.artistText
                            .font(.system(size: 10, weight: .medium))
                            .opacity(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    self.hoverOnly {
                        self.trackActionButtons
                    }
                }

                self.seekSection
                self.transportControls(playSize: 25, sideSize: 16, spacing: 30)
            }
            .padding(.top, Self.Layout.headerTopInset)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Group {
                switch self.detailPane {
                case .lyrics:
                    Group {
                        if !self.settings.useLegacyMacOS15UI, #available(macOS 26.0, *) {
                            LyricsView(client: self.client, showsHeader: false, preferredWidth: nil)
                        } else {
                            SimpleLyricsView(client: self.client, showsHeader: false, preferredWidth: nil)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.MiniPlayer.lyricsView)
                case .queue:
                    self.queuePane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    private var trafficLights: some View {
        HStack(spacing: 7) {
            self.trafficButton(color: .red, accessibilityLabel: String(localized: "Close"), accessibilityID: AccessibilityID.MiniPlayer.closeButton) {
                MiniPlayerWindowController.shared.closeFromUserAction()
            }
            self.trafficButton(color: .yellow, accessibilityLabel: String(localized: "Minimize"), accessibilityID: AccessibilityID.MiniPlayer.minimizeButton) {
                MiniPlayerWindowController.shared.miniaturizeFromUserAction()
            }
            self.trafficButton(color: .green, accessibilityLabel: self.expandCollapseLabel, accessibilityID: AccessibilityID.MiniPlayer.expandButton) {
                self.playerService.toggleMiniPlayerPanel()
            }
        }
    }

    private var hoverCommandPill: some View {
        HStack(spacing: 11) {
            self.hoverIconButton(
                systemName: "macwindow",
                accessibilityID: AccessibilityID.MiniPlayer.returnToKasetButton,
                label: String(localized: "Return to Kaset")
            ) {
                MiniPlayerWindowController.shared.returnToMainWindowFromUserAction()
            }

            self.hoverIconButton(
                systemName: self.panelToggleIcon,
                accessibilityID: AccessibilityID.MiniPlayer.panelToggleButton,
                label: self.panelToggleLabel,
                isActive: self.playerService.miniPlayerPanel == .expanded
            ) {
                self.playerService.toggleMiniPlayerPanel()
            }

            self.hoverIconButton(
                systemName: "quote.bubble",
                accessibilityID: AccessibilityID.MiniPlayer.lyricsButton,
                label: String(localized: "Lyrics"),
                isActive: self.playerService.miniPlayerPanel == .lyrics && self.detailPane == .lyrics
            ) {
                if self.playerService.miniPlayerPanel == .lyrics, self.detailPane == .lyrics {
                    self.playerService.miniPlayerPanel = .compact
                } else {
                    self.detailPane = .lyrics
                    self.playerService.miniPlayerPanel = .lyrics
                }
            }

            self.hoverIconButton(
                systemName: "list.bullet",
                accessibilityID: AccessibilityID.MiniPlayer.queueButton,
                label: String(localized: "Queue"),
                isActive: self.playerService.miniPlayerPanel == .lyrics && self.detailPane == .queue
            ) {
                if self.playerService.miniPlayerPanel == .lyrics, self.detailPane == .queue {
                    self.playerService.miniPlayerPanel = .compact
                } else {
                    self.detailPane = .queue
                    self.playerService.miniPlayerPanel = .lyrics
                }
            }

            self.airPlayButton

            self.hoverIconButton(systemName: self.volumeIcon, accessibilityID: AccessibilityID.MiniPlayer.volumeButton, label: String(localized: "Volume"), isActive: self.playerService.isMuted) {
                Task { await self.playerService.toggleMute() }
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white.opacity(0.94))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.black.opacity(0.18), in: .capsule)
        .compatGlass(interactive: true, in: .capsule)
        .overlay {
            Capsule()
                .stroke(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.42),
                            .white.opacity(0.10),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.36), radius: 16, y: 6)
    }

    private func hoverOnly(@ViewBuilder content: () -> some View) -> some View {
        content()
            .opacity(self.isHovering ? 1 : 0)
            .blur(radius: self.isHovering ? 0 : 4)
            .scaleEffect(self.isHovering ? 1 : 0.97)
            .animation(AppAnimation.snappy, value: self.isHovering)
    }

    private func trafficButton(color: Color, accessibilityLabel: String, accessibilityID: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: Self.Layout.trafficLightSize, height: Self.Layout.trafficLightSize)
                .overlay {
                    Circle()
                        .stroke(.black.opacity(0.20), lineWidth: 0.8)
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityLabel(accessibilityLabel)
    }

    private func hoverIconButton(systemName: String, accessibilityID: String, label: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            MiniPlayerGlassIconLabel(systemName: systemName, isActive: isActive, size: 22)
        }
        .buttonStyle(.plain)
        .compatGlass(interactive: true, in: .circle)
        .shadow(color: .black.opacity(0.46), radius: 7, y: 2)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityLabel(label)
        .help(label)
        .disabled(self.playerService.currentTrack == nil && !self.isEnabledWithoutTrack(accessibilityID: accessibilityID))
    }

    private func isEnabledWithoutTrack(accessibilityID: String) -> Bool {
        accessibilityID == AccessibilityID.MiniPlayer.volumeButton ||
            accessibilityID == AccessibilityID.MiniPlayer.panelToggleButton ||
            accessibilityID == AccessibilityID.MiniPlayer.returnToKasetButton
    }

    private var airPlayButton: some View {
        ZStack {
            MiniPlayerAirPlayRoutePickerView()
                .frame(width: 22, height: 22)

            MiniPlayerGlassIconLabel(systemName: "airplayaudio", isActive: self.playerService.isAirPlayConnected, size: 22)
                .allowsHitTesting(false)
        }
        .compatGlass(interactive: true, in: .circle)
        .shadow(color: .black.opacity(0.46), radius: 7, y: 2)
        .accessibilityIdentifier(AccessibilityID.MiniPlayer.airplayButton)
        .accessibilityLabel(self.playerService.isAirPlayConnected ? String(localized: "AirPlay Connected") : String(localized: "AirPlay"))
        .disabled(self.playerService.currentTrack == nil)
        .simultaneousGesture(TapGesture().onEnded {
            self.playerService.markAirPlayRequested()
        })
    }

    private var trackActionButtons: some View {
        HStack(spacing: 5) {
            self.likeButton
            self.moreMenu
        }
    }

    private var likeButton: some View {
        let isLiked = self.playerService.currentTrackLikeStatus == .like
        let label = isLiked ? String(localized: "Remove Like") : String(localized: "Like")

        return Button {
            self.playerService.likeCurrentTrack()
        } label: {
            MiniPlayerGlassIconLabel(systemName: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup", isActive: isLiked, size: 23, fontSize: 12)
        }
        .buttonStyle(.plain)
        .compatGlass(interactive: true, in: .circle)
        .shadow(color: .black.opacity(0.46), radius: 7, y: 2)
        .disabled(self.playerService.currentTrack == nil)
        .accessibilityIdentifier(AccessibilityID.MiniPlayer.likeButton)
        .accessibilityLabel(label)
        .accessibilityValue(isLiked ? String(localized: "Liked") : String(localized: "Not liked"))
        .help(label)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                self.playerService.toggleLibraryStatus()
            } label: {
                Label(
                    self.playerService.currentTrackInLibrary ? "Remove from Library" : "Add to Library",
                    systemImage: self.playerService.currentTrackInLibrary ? "minus.circle" : "plus.circle"
                )
            }
            .disabled(self.playerService.currentTrack == nil)

            Button {
                self.playerService.dislikeCurrentTrack()
            } label: {
                Label(
                    self.playerService.currentTrackLikeStatus == .dislike ? "Remove Dislike" : "Dislike",
                    systemImage: self.playerService.currentTrackLikeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown"
                )
            }
            .disabled(self.playerService.currentTrack == nil)
        } label: {
            MiniPlayerGlassIconLabel(systemName: "ellipsis", isActive: false, size: 23, fontSize: 12)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .compatGlass(interactive: true, in: .circle)
        .shadow(color: .black.opacity(0.46), radius: 7, y: 2)
        .accessibilityLabel(String(localized: "More"))
    }

    private func artwork(size: CGFloat, cornerRadius: CGFloat) -> some View {
        Group {
            if let track = self.playerService.currentTrack {
                SongThumbnailView(song: track, size: size, cornerRadius: cornerRadius)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.white.opacity(0.88))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(.black.opacity(0.32))
                    }
                    .frame(width: size, height: size)
            }
        }
        .shadow(color: .black.opacity(0.20), radius: 10, y: 4)
    }

    private var fullFrameArtwork: some View {
        Group {
            if let track = self.playerService.currentTrack {
                SongThumbnailView(song: track, size: 320, cornerRadius: 0)
                    .scaleEffect(1.04)
            } else {
                Rectangle()
                    .fill(.white.opacity(0.88))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 96, weight: .semibold))
                            .foregroundStyle(.black.opacity(0.32))
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var squareArtworkTopBackdrop: some View {
        VStack {
            LinearGradient(
                colors: [
                    .black.opacity(0.58),
                    .black.opacity(0.34),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 104)

            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var squareArtworkControlBackdrop: some View {
        VStack {
            Spacer()
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .blur(radius: 22)
                    .opacity(0.66)

                LinearGradient(
                    colors: [
                        .clear,
                        .black.opacity(0.40),
                        .black.opacity(0.86),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: 170)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.65), location: 0.26),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .allowsHitTesting(false)
    }

    private var titleText: some View {
        Text(self.playerService.currentTrack?.title ?? String(localized: "Not Playing"))
            .lineLimit(1)
            .foregroundStyle(.white.opacity(0.96))
            .shadow(color: .black.opacity(0.62), radius: 2, y: 1)
            .accessibilityIdentifier(AccessibilityID.MiniPlayer.trackTitle)
    }

    private var artistText: some View {
        Text(self.playerService.currentTrack?.artistsDisplay.isEmpty == false ? self.playerService.currentTrack?.artistsDisplay ?? "" : String(localized: "Kaset"))
            .lineLimit(1)
            .foregroundStyle(.white.opacity(0.78))
            .shadow(color: .black.opacity(0.58), radius: 2, y: 1)
            .accessibilityIdentifier(AccessibilityID.MiniPlayer.trackArtist)
    }

    private var seekSection: some View {
        VStack(spacing: 8) {
            Slider(value: self.$seekValue, in: 0 ... 1) { editing in
                self.isSeeking = editing
                if !editing {
                    self.performSeek()
                }
            }
            .controlSize(.small)
            .tint(PackageResourceLookup.brandAccent)
            .disabled(self.playerService.duration <= 0 || self.playerService.isCurrentItemLive)
            .accessibilityIdentifier(AccessibilityID.MiniPlayer.seekSlider)

            HStack {
                Text(self.formatTime(self.isSeeking ? self.seekValue * self.playerService.duration : self.playerService.progress))
                Spacer()
                Text(self.playerService.isCurrentItemLive ? String(localized: "LIVE") : self.remainingTimeText)
            }
            .font(.system(size: 9, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.76))
            .shadow(color: .black.opacity(0.56), radius: 2, y: 1)
        }
    }

    private func transportControls(playSize: CGFloat, sideSize: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            self.transportButton(
                systemName: "shuffle",
                size: sideSize,
                active: self.playerService.shuffleEnabled,
                accessibilityID: AccessibilityID.MiniPlayer.shuffleButton,
                label: String(localized: "Shuffle")
            ) {
                self.playerService.toggleShuffle()
            }

            self.transportButton(
                systemName: "backward.fill",
                size: sideSize + 2,
                accessibilityID: AccessibilityID.MiniPlayer.previousButton,
                label: String(localized: "Previous track")
            ) {
                Task { await self.playerService.previous() }
            }
            .disabled(self.playerService.currentEpisode != nil)

            self.transportButton(
                systemName: self.playerService.isPlaying ? "pause.fill" : "play.fill",
                size: playSize,
                accessibilityID: AccessibilityID.MiniPlayer.playPauseButton,
                label: self.playerService.isPlaying ? String(localized: "Pause") : String(localized: "Play")
            ) {
                Task { await self.playerService.playPause() }
            }

            self.transportButton(
                systemName: "forward.fill",
                size: sideSize + 2,
                accessibilityID: AccessibilityID.MiniPlayer.nextButton,
                label: String(localized: "Next track")
            ) {
                Task { await self.playerService.next() }
            }
            .disabled(self.playerService.currentEpisode != nil)

            self.transportButton(
                systemName: self.repeatIcon,
                size: sideSize,
                active: self.playerService.repeatMode != .off,
                accessibilityID: AccessibilityID.MiniPlayer.repeatButton,
                label: String(localized: "Repeat")
            ) {
                self.playerService.cycleRepeatMode()
            }
        }
    }

    private func transportButton(
        systemName: String,
        size: CGFloat,
        active: Bool = false,
        accessibilityID: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(active ? PackageResourceLookup.brandAccent : .white.opacity(0.90))
                .frame(width: max(21, size + 7), height: max(21, size + 7))
                .shadow(color: .black.opacity(0.62), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityLabel(label)
    }

    private var queuePane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if self.playerService.queue.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No Queue"),
                        systemImage: "list.bullet",
                        description: Text("Songs you play next will appear here.")
                    )
                    .foregroundStyle(.white.opacity(0.76))
                    .frame(maxWidth: .infinity, minHeight: 210)
                } else {
                    ForEach(Array(self.playerService.queue.enumerated()), id: \.offset) { index, song in
                        HStack(spacing: 7) {
                            SongThumbnailView(song: song, size: 21, cornerRadius: 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title)
                                    .font(.system(size: 9, weight: index == self.playerService.currentIndex ? .semibold : .regular))
                                    .lineLimit(1)
                                Text(song.artistsDisplay)
                                    .font(.system(size: 8))
                                    .foregroundStyle(.white.opacity(0.58))
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(index == self.playerService.currentIndex ? Color.white.opacity(0.12) : Color.clear, in: .rect(cornerRadius: 10))
                    }
                }
            }
            .padding(8)
        }
        .background(.white.opacity(0.07), in: .rect(cornerRadius: 12))
    }

    private var showsCommandPill: Bool {
        self.isHovering || self.playerService.miniPlayerPanel == .expanded
    }

    private var panelToggleIcon: String {
        self.playerService.miniPlayerPanel == .expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
    }

    private var panelToggleLabel: String {
        self.playerService.miniPlayerPanel == .expanded ? String(localized: "Show Regular Mini Player") : String(localized: "Show Large Artwork")
    }

    private var expandCollapseLabel: String {
        self.panelToggleLabel
    }

    private var remainingTimeText: String {
        "-\(self.formatTime(max(0, self.playerService.duration - self.playerService.progress)))"
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
        let value = self.isAdjustingVolume ? self.volumeValue : self.playerService.volume
        if value == 0 {
            return "speaker.slash.fill"
        } else if value < 0.5 {
            return "speaker.wave.1.fill"
        } else {
            return "speaker.wave.2.fill"
        }
    }

    private func syncSeekValue() {
        if self.playerService.duration > 0 {
            self.seekValue = self.playerService.progress / self.playerService.duration
        } else {
            self.seekValue = 0
        }
    }

    private func performSeek() {
        guard self.playerService.duration > 0 else { return }
        let target = self.seekValue * self.playerService.duration
        Task { await self.playerService.seek(to: target) }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }
}
