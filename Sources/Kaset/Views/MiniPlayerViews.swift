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
@available(macOS 26.0, *)
struct MiniPlayerToast: View {
    let videoId: String

    var body: some View {
        PersistentPlayerView(videoId: self.videoId, isExpanded: true)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .glassEffectTransition(.materialize)
    }
}

// MARK: - MiniPlayerWindow

@available(macOS 26.0, *)
struct MiniPlayerWindow: View {
    private enum DetailPane {
        case lyrics
        case queue
    }

    @Environment(PlayerService.self) private var playerService

    let client: any YTMusicClientProtocol

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
                .opacity(self.isHovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.14), value: self.isHovering)
        }
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
        .onChange(of: self.playerService.miniPlayerPanel) { _, _ in
            MiniPlayerWindowController.shared.syncWindowState()
        }
        .onChange(of: SettingsManager.shared.keepMiniPlayerOnTop) { _, _ in
            MiniPlayerWindowController.shared.syncWindowState()
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
            .fill(.black.opacity(self.playerService.miniPlayerPanel == .expanded ? 0.84 : 0.62))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: self.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
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
        }
        .padding(.top, 12)
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
                    HStack(spacing: 5) {
                        self.favoriteButton
                        self.moreMenu
                    }
                }
            }

            self.seekSection
            self.transportControls(playSize: 25, sideSize: 16, spacing: 30)
        }
        .padding(.top, 26)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var squareArtworkBody: some View {
        ZStack(alignment: .bottom) {
            self.fullFrameArtwork

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
                        HStack(spacing: 5) {
                            self.favoriteButton
                            self.moreMenu
                        }
                    }
                }

                self.seekSection
                self.transportControls(playSize: 27, sideSize: 17, spacing: 30)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .opacity(self.isHovering ? 1 : 0)
            .animation(.easeInOut(duration: 0.14), value: self.isHovering)
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
                        self.moreMenu
                    }
                }

                self.seekSection
                self.transportControls(playSize: 25, sideSize: 16, spacing: 30)
            }
            .padding(.top, 26)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Group {
                switch self.detailPane {
                case .lyrics:
                    LyricsView(client: self.client, showsHeader: false, preferredWidth: nil)
                        .accessibilityIdentifier(AccessibilityID.MiniPlayer.lyricsButton)
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
            self.trafficButton(color: .red, accessibilityLabel: String(localized: "Close")) {
                MiniPlayerWindowController.shared.closeFromUserAction()
            }
            self.trafficButton(color: .yellow, accessibilityLabel: String(localized: "Minimize")) {
                NSApp.keyWindow?.miniaturize(nil)
            }
            self.trafficButton(color: .green, accessibilityLabel: self.expandCollapseLabel) {
                self.playerService.toggleMiniPlayerPanel()
            }
        }
    }

    private var hoverCommandPill: some View {
        HStack(spacing: 11) {
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
                self.detailPane = .queue
                self.playerService.miniPlayerPanel = .lyrics
            }

            self.hoverIconButton(systemName: "airplayaudio", accessibilityID: AccessibilityID.MiniPlayer.airplayButton, label: String(localized: "AirPlay"), isActive: self.playerService.isAirPlayConnected) {
                self.playerService.showAirPlayPicker()
            }

            self.hoverIconButton(systemName: self.volumeIcon, accessibilityID: AccessibilityID.MiniPlayer.volumeSlider, label: String(localized: "Volume"), isActive: self.playerService.isMuted) {
                Task { await self.playerService.toggleMute() }
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.white.opacity(0.20), in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private func hoverOnly(@ViewBuilder content: () -> some View) -> some View {
        content()
            .opacity(self.isHovering ? 1 : 0)
            .animation(.easeInOut(duration: 0.14), value: self.isHovering)
    }

    private func trafficButton(color: Color, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 13, height: 13)
                .overlay {
                    Circle()
                        .stroke(.black.opacity(0.20), lineWidth: 0.8)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func hoverIconButton(systemName: String, accessibilityID: String, label: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 22, height: 22)
                .background(isActive ? PackageResourceLookup.brandAccent.opacity(0.18) : .clear, in: .circle)
                .overlay {
                    Circle()
                        .stroke(isActive ? PackageResourceLookup.brandAccent : .clear, lineWidth: 1.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityLabel(label)
        .disabled(self.playerService.currentTrack == nil && accessibilityID != AccessibilityID.MiniPlayer.volumeSlider)
    }

    private var favoriteButton: some View {
        Button {
            self.playerService.toggleLibraryStatus()
        } label: {
            Image(systemName: self.playerService.currentTrackInLibrary ? "star.fill" : "star")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 23, height: 23)
                .foregroundStyle(self.playerService.currentTrackInLibrary ? .yellow : .white.opacity(0.9))
                .background(.white.opacity(0.18), in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(self.playerService.currentTrack == nil)
        .accessibilityLabel(self.playerService.currentTrackInLibrary ? String(localized: "Remove from Library") : String(localized: "Add to Library"))
    }

    private var moreMenu: some View {
        Menu {
            Button("Favorite") {
                self.playerService.toggleLibraryStatus()
            }
            .disabled(self.playerService.currentTrack == nil)

            Button("Suggest Less") {
                self.playerService.dislikeCurrentTrack()
            }
            .disabled(self.playerService.currentTrack == nil)

            Divider()

            Button("Show Playing Next") {
                self.detailPane = .queue
                self.playerService.miniPlayerPanel = .lyrics
            }

            Button(self.playerService.miniPlayerPanel == .lyrics && self.detailPane == .lyrics ? "Hide Lyrics" : "Show Lyrics") {
                if self.playerService.miniPlayerPanel == .lyrics, self.detailPane == .lyrics {
                    self.playerService.miniPlayerPanel = .compact
                } else {
                    self.detailPane = .lyrics
                    self.playerService.miniPlayerPanel = .lyrics
                }
            }

            Divider()

            Button("Close Mini Player") {
                MiniPlayerWindowController.shared.closeFromUserAction()
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 23, height: 23)
                .foregroundStyle(.white.opacity(0.92))
                .background(.white.opacity(0.18), in: .circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
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

    private var squareArtworkControlBackdrop: some View {
        VStack {
            Spacer()
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .blur(radius: 18)
                    .opacity(0.58)

                LinearGradient(
                    colors: [
                        .clear,
                        .black.opacity(0.24),
                        .black.opacity(0.70),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: 132)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.55), location: 0.34),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    private var titleText: some View {
        Text(self.playerService.currentTrack?.title ?? String(localized: "Not Playing"))
            .lineLimit(1)
            .foregroundStyle(.white.opacity(0.96))
            .accessibilityIdentifier(AccessibilityID.MiniPlayer.trackTitle)
    }

    private var artistText: some View {
        Text(self.playerService.currentTrack?.artistsDisplay.isEmpty == false ? self.playerService.currentTrack?.artistsDisplay ?? "" : String(localized: "Kaset"))
            .lineLimit(1)
            .foregroundStyle(.white.opacity(0.72))
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
            .foregroundStyle(.white.opacity(0.66))
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
                .foregroundStyle(active ? PackageResourceLookup.brandAccent : .white.opacity(0.86))
                .frame(width: max(21, size + 7), height: max(21, size + 7))
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
                    ForEach(Array(self.playerService.queue.enumerated()), id: \.element.videoId) { index, song in
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

    private var expandCollapseLabel: String {
        self.playerService.miniPlayerPanel == .compact ? String(localized: "Show Large Artwork") : String(localized: "Collapse Mini Player")
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
