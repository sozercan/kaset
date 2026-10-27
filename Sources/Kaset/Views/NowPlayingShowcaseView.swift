import AppKit
import SwiftUI

// MARK: - NowPlayingShowcaseView

/// Expanded artwork and a persistent detail panel, sharing the main player's transport.
struct NowPlayingShowcaseView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settings = SettingsManager.shared
    @State private var preferredPanelWidth = SettingsManager.shared.nowPlayingQueueWidth.map { CGFloat($0) } ?? 340
    @State private var dragStartWidth: CGFloat?
    @State private var isHoveringResize = false

    let client: any YTMusicClientProtocol

    var body: some View {
        GeometryReader { proxy in
            let panelWidth = NowPlayingShowcaseLayout.panelWidth(in: proxy.size.width, preferred: self.preferredPanelWidth)
            let panelAllowance = self.playerService.nowPlayingPanel == nil ? nil : panelWidth
            let artworkSize = NowPlayingShowcaseLayout.artworkSize(in: proxy.size, panelWidth: panelAllowance)
            let videoSize = NowPlayingShowcaseLayout.videoSize(in: proxy.size, panelWidth: panelAllowance)

            ZStack {
                if let track = self.playerService.currentTrack {
                    ShowcaseAmbientBackdrop(track: track)
                }

                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: self.close)

                VStack(spacing: 12) {
                    HStack {
                        self.closeButton
                        Spacer()
                        self.panelControls
                            .frame(width: panelWidth, alignment: .trailing)
                    }
                    .frame(height: 36)

                    HStack(spacing: 24) {
                        self.mainColumn(artworkSize: artworkSize, videoSize: videoSize)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if let panel = self.playerService.nowPlayingPanel {
                            self.detailPanel(panel, width: panelWidth)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(self.reduceMotion ? nil : AppAnimation.standard, value: self.playerService.showNowPlayingVideo)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 76)
            }
        }
        .background { ShowcaseEscapeKeyMonitor(onEscape: self.close) }
        .onChange(of: self.playerService.showNowPlayingVideo) { _, _ in
            self.updateVideoReadiness()
        }
        .onChange(of: self.playerService.currentTrack?.videoId) { _, _ in
            // Persistent video mode across auto-advance never flips
            // showNowPlayingVideo, so the cover must re-arm on every MV load.
            self.updateVideoReadiness()
        }
        .onChange(of: self.playerService.pendingPlayVideoId) { _, _ in
            self.updateVideoReadiness()
        }
        .onDisappear {
            self.videoReadyTask?.cancel()
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private func mainColumn(artworkSize: CGFloat, videoSize: CGSize) -> some View {
        if let track = self.playerService.currentTrack {
            VStack(spacing: 20) {
                // Video mode swaps the surface into the artwork's place in the
                // main column; the trailing panel keeps its own content.
                if self.playerService.shouldHostPlaybackInShowcase {
                    self.videoSurface(size: videoSize)
                        .transition(.opacity)
                } else {
                    ShowcaseArtworkView(song: track, size: artworkSize, cornerRadius: 16)
                        .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
                }

                VStack(spacing: 6) {
                    Text(track.title)
                        .font(.title.weight(.bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(track.artistsDisplay.isEmpty ? String(localized: "Unknown Artist") : track.artistsDisplay)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            Text("Not Playing")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Panel

    private var panelControls: some View {
        HStack(spacing: 4) {
            ForEach(PlayerService.NowPlayingPanel.allCases, id: \.self) { panel in
                self.tabButton(panel)
            }
            self.videoToggleButton
            self.miniPlayerToggleButton
            Divider().frame(height: 18).padding(.horizontal, 6)
            self.collapseButton
        }
    }

    /// Mini-player (pip) toggle, moved up from the bar while the overlay is
    /// open. Same action as the bar's button: the video window cannot keep
    /// hosting when the mini player takes over.
    private var miniPlayerToggleButton: some View {
        let isSelected = self.playerService.isMiniPlayerVisible
        return Button {
            HapticService.toggle()
            self.playerService.showVideo = false
            _ = self.playerService.toggleMiniPlayer(mode: .switchFromMainWindow)
        } label: {
            Image(systemName: isSelected ? "arrow.up.left.and.arrow.down.right" : "macwindow")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 36)
                .foregroundStyle(isSelected ? PackageResourceLookup.brandAccent : .primary)
                .background(isSelected ? Color.primary.opacity(0.10) : .clear, in: .rect(cornerRadius: 10))
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Capsule().fill(PackageResourceLookup.brandAccent).frame(width: 12, height: 2).padding(.bottom, 3)
                    }
                }
                .contentShape(.rect(cornerRadius: 10))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.PlayerBar.miniPlayerButton)
        .accessibilityLabel(isSelected ? String(localized: "Return to Kaset") : String(localized: "Switch to Mini Player"))
        .accessibilityValue(isSelected ? String(localized: "Showing") : String(localized: "Hidden"))
        .help(isSelected ? String(localized: "Return to Kaset") : String(localized: "Switch to Mini Player"))
    }

    /// TV toggle: swaps the showcase's album cover for the music video and
    /// back. Lives only here — video is watched in the overlay, not from the
    /// bar. Styled like the panel tabs so hover feedback matches.
    private var videoToggleButton: some View {
        let isSelected = self.playerService.showNowPlayingVideo
        return Button {
            HapticService.toggle()
            Task { await self.playerService.toggleNowPlayingVideo() }
        } label: {
            Image(systemName: isSelected ? "tv.fill" : "tv")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 36)
                .foregroundStyle(isSelected ? PackageResourceLookup.brandAccent : .primary)
                .background(isSelected ? Color.primary.opacity(0.10) : .clear, in: .rect(cornerRadius: 10))
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Capsule().fill(PackageResourceLookup.brandAccent).frame(width: 12, height: 2).padding(.bottom, 3)
                    }
                }
                .contentShape(.rect(cornerRadius: 10))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!isSelected && !self.playerService.canShowCurrentTrackVideo)
        .accessibilityIdentifier(AccessibilityID.PlayerBar.videoButton)
        .accessibilityLabel(String(localized: "Video"))
        .accessibilityValue(isSelected ? String(localized: "Showing") : String(localized: "Hidden"))
        .help(isSelected ? String(localized: "Show Album Artwork") : String(localized: "Show Music Video"))
    }

    private func tabButton(_ panel: PlayerService.NowPlayingPanel) -> some View {
        let isSelected = self.playerService.nowPlayingPanel == panel
        return Button {
            HapticService.toggle()
            withAnimation(self.playerService.nowPlayingPanel == nil || self.reduceMotion ? nil : AppAnimation.quick) {
                self.playerService.nowPlayingPanel = panel
            }
        } label: {
            Image(systemName: panel.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isSelected ? PackageResourceLookup.brandAccent : .primary)
                .frame(width: 36, height: 36)
                .background(isSelected ? Color.primary.opacity(0.10) : .clear, in: .rect(cornerRadius: 10))
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Capsule().fill(PackageResourceLookup.brandAccent).frame(width: 12, height: 2).padding(.bottom, 3)
                    }
                }
                .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(panel.title) // [VERIFY] confirm tab names in VoiceOver.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(panel.accessibilityID)
        .help(panel.title)
    }

    private func detailPanel(_ panel: PlayerService.NowPlayingPanel, width: CGFloat) -> some View {
        let content = ZStack {
            switch panel {
            case .queue:
                QueueView(width: width, isEmbedded: true)
            case .lyrics:
                if !self.settings.useLegacyMacOS15UI, #available(macOS 26.0, *) {
                    LyricsView(client: self.client, preferredWidth: nil, isEmbedded: true)
                } else {
                    SimpleLyricsView(client: self.client, preferredWidth: nil, isEmbedded: true)
                }
            case .recommendations:
                ShowcaseRecommendationsView(client: self.client)
            }
        }
        .id(panel)
        .transition(.opacity)
        .frame(width: width)
        .frame(maxHeight: .infinity)

        return Group {
            if panel == .queue {
                // NSTableView drag-and-drop needs a material surface outside Liquid Glass.
                content.background(.regularMaterial)
            } else {
                content.compatGlass(in: .rect(cornerRadius: 20))
            }
        }
        .clipShape(.rect(cornerRadius: 20))
        .contentShape(.rect(cornerRadius: 20))
        .overlay(alignment: .leading) { self.resizeHandle(width: width) }
    }

    private func resizeHandle(width: CGFloat) -> some View {
        Color.clear
            .frame(width: 16)
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(Color.secondary.opacity(self.isHoveringResize ? 0.6 : 0))
                    .frame(width: 3, height: 36)
            }
            .offset(x: -12)
            .onHover { self.isHoveringResize = $0 }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if self.dragStartWidth == nil {
                            self.dragStartWidth = width
                        }
                        self.preferredPanelWidth = min(max((self.dragStartWidth ?? width) - value.translation.width, 300), 560)
                    }
                    .onEnded { _ in
                        self.settings.nowPlayingQueueWidth = Double(self.preferredPanelWidth)
                        self.dragStartWidth = nil
                    }
            )
    }

    /// The video surface: video mode swaps it into the artwork's place in the main
    /// column. Same singleton playback WebView as every other host. Until the
    /// video element is actually rendering, an opaque cover hides the page
    /// content behind it (no flash of the YouTube Music UI) and shows a loader.
    private func videoSurface(size: CGSize) -> some View {
        VideoWebViewContainer(videoId: self.playerService.pendingPlayVideoId, isShowcase: true)
            .frame(width: size.width, height: size.height)
            .background(.black)
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
            .overlay {
                if self.playerService.showNowPlayingVideo, !self.videoReady {
                    ZStack {
                        Color.black
                        ProgressView()
                            .controlSize(.regular)
                    }
                    .transition(self.reduceMotion ? .opacity : .opacity)
                }
            }
            .contentShape(.rect(cornerRadius: 16, style: .continuous))
            .accessibilityIdentifier("nowPlaying.video")
    }

    /// True once the loaded stream's video element reports real dimensions.
    /// Polled after video mode turns on or the loaded video changes; resets on
    /// toggle-off so every MV load is covered again.
    @State private var videoReady = false
    @State private var videoReadyTask: Task<Void, Never>?

    private func updateVideoReadiness() {
        self.videoReadyTask?.cancel()
        guard self.playerService.showNowPlayingVideo else {
            self.videoReady = false
            return
        }
        // A previous MV's readiness must not carry over: each load is covered
        // until ITS video element reports dimensions.
        self.videoReady = false
        self.videoReadyTask = Task {
            // Cover the page flash while the MV loads; reveal on first real
            // video frame, or after a generous timeout as a failsafe.
            for _ in 0 ..< 60 {
                if Task.isCancelled {
                    return
                }
                if await SingletonPlayerWebView.shared.loadedStreamHasVideoContent() {
                    self.videoReady = true
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self.videoReady = true
        }
    }

    private var collapseButton: some View {
        PlayerBarIconButton(
            action: {
                HapticService.toggle()
                withAnimation(self.playerService.nowPlayingPanel == nil || self.reduceMotion ? nil : AppAnimation.quick) {
                    self.playerService.nowPlayingPanel = self.playerService.nowPlayingPanel == nil ? .queue : nil
                }
            },
            size: 36,
            accessibilityLabel: self.playerService.nowPlayingPanel == nil ? String(localized: "Show Panel") : String(localized: "Hide Panel"),
            icon: {
                Image(systemName: self.playerService.nowPlayingPanel == nil ? "sidebar.right" : "chevron.right")
                    .font(.system(size: 13, weight: .medium))
            }
        )
    }

    private var closeButton: some View {
        PlayerBarIconButton(
            action: self.close,
            size: 36,
            accessibilityLabel: String(localized: "Close"),
            icon: { Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold)) }
        )
    }

    private func close() {
        withAnimation(self.reduceMotion ? nil : AppAnimation.quick) {
            self.playerService.showNowPlayingShowcase = false
        }
    }
}

extension PlayerService.NowPlayingPanel {
    var title: String {
        switch self {
        case .lyrics: String(localized: "Lyrics")
        case .queue: String(localized: "Up Next")
        case .recommendations: String(localized: "Recommendations")
        }
    }

    var symbol: String {
        switch self {
        case .lyrics: "quote.bubble"
        case .queue: "list.bullet"
        case .recommendations: "sparkles"
        }
    }

    var accessibilityID: String {
        switch self {
        case .lyrics: AccessibilityID.PlayerBar.lyricsButton
        case .queue: AccessibilityID.PlayerBar.queueButton
        case .recommendations: "nowPlaying.recommendations"
        }
    }
}

// MARK: - NowPlayingShowcaseLayout

enum NowPlayingShowcaseLayout {
    static func panelWidth(in windowWidth: CGFloat, preferred: CGFloat) -> CGFloat {
        min(max(preferred, 300), 560, max(300, windowWidth * 0.46))
    }

    /// The 16:9 video surface size that fits the main column next to the panel,
    /// using the same budgets as the artwork size.
    static func videoSize(in size: CGSize, panelWidth: CGFloat?) -> CGSize {
        let panelAllowance = panelWidth.map { $0 + 24 } ?? 0
        let maxWidth = size.width - 48 - panelAllowance
        let maxHeight = size.height - 264
        let height = max(120, min(maxHeight, maxWidth * 9 / 16))
        return CGSize(width: height * 16 / 9, height: height)
    }

    static func artworkSize(in size: CGSize, panelWidth: CGFloat?) -> CGFloat {
        let panelAllowance = panelWidth.map { $0 + 24 } ?? 0
        return max(120, min(400, size.height - 264, size.width - 48 - panelAllowance))
    }
}

// MARK: - ShowcaseAmbientBackdrop

/// Keep the per-tick playback observation out of the showcase's layout and controls.
private struct ShowcaseAmbientBackdrop: View {
    @Environment(PlayerService.self) private var playerService
    let track: Song

    var body: some View {
        let isVideo = self.playerService.shouldHostPlaybackInShowcase
        AmbientVideoBackdrop(
            videoId: self.track.videoId,
            thumbnailURL: self.track.thumbnailURL?.highQualityThumbnailURL ?? self.track.fallbackThumbnailURL,
            style: isVideo ? .live : .glow,
            liveFraction: isVideo && self.playerService.duration > 0 ? min(max(self.playerService.progress / self.playerService.duration, 0), 1) : nil,
            storyboardSpec: nil
        )
        .ignoresSafeArea()
    }
}

// MARK: - ShowcaseArtworkView

/// High-resolution artwork for the showcase. `SongThumbnailView` fetches at its
/// display size via `highQualityThumbnailURL` (capped at 226px), which blurs
/// badly at the showcase's 160-400pt; this fetches an 800px variant instead and
/// keeps the same primary-URL failure fallback.
private struct ShowcaseArtworkView: View {
    let song: Song
    let size: CGFloat
    let cornerRadius: CGFloat

    @State private var failedPrimaryKey: SongThumbnailSource.PrimaryFailureKey?

    private var thumbnailSource: SongThumbnailSource {
        SongThumbnailSource(
            videoId: self.song.videoId,
            primaryURL: self.song.thumbnailURL?.largeThumbnailURL,
            fallbackURL: self.song.fallbackThumbnailURL
        )
    }

    /// The URL to display: primary first, fallback only if that exact primary source failed.
    private var activeURL: URL? {
        self.thumbnailSource.activeURL(failedPrimaryKey: self.failedPrimaryKey)
    }

    private var failureHandler: (@MainActor () -> Void)? {
        let source = self.thumbnailSource

        guard self.activeURL == source.primaryURL,
              let primaryFailureKey = source.primaryFailureKey
        else {
            return nil
        }

        return {
            self.failedPrimaryKey = primaryFailureKey
        }
    }

    var body: some View {
        CachedAsyncImage(
            url: self.activeURL,
            targetSize: CGSize(width: 800, height: 800),
            onFailure: self.failureHandler
        ) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: self.size, height: self.size)
        .clipShape(.rect(cornerRadius: self.cornerRadius, style: .continuous))
    }
}

// MARK: - Player Bar Title Affordance

extension View {
    /// Hover affordance for the player bar's clickable song-title area:
    /// pointing-hand cursor plus a subtle emphasis shift.
    func playerBarTitleHoverAffordance() -> some View {
        self.modifier(PlayerBarTitleHoverAffordance())
    }
}

// MARK: - PlayerBarTitleHoverAffordance

private struct PlayerBarTitleHoverAffordance: ViewModifier {
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(self.isHovered ? 1.0 : 0.88)
            .shadow(color: PackageResourceLookup.brandAccent.opacity(self.isHovered ? 0.35 : 0), radius: 4)
            .animation(self.reduceMotion ? nil : AppAnimation.quick, value: self.isHovered)
            .onHover { hovering in
                self.isHovered = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

// MARK: - ShowcaseEscapeKeyMonitor

/// Local key monitor that dismisses the showcase on Esc, regardless of which
/// view holds first responder. Same pattern as `YouTubeAskEscapeKeyMonitor` in
/// `YouTubeAskPanelView.swift`.
private struct ShowcaseEscapeKeyMonitor: NSViewRepresentable {
    let onEscape: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: self.onEscape)
    }

    func makeNSView(context: Context) -> NSView {
        let view = ShowcaseEscapeHostView(frame: .zero)
        view.isHidden = true
        view.onMoveToWindow = { window in
            context.coordinator.install(window: window)
        }
        context.coordinator.install(window: view.window)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onEscape = self.onEscape
        context.coordinator.install(window: view.window)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        _ = view
        coordinator.uninstall()
    }

    /// Host view that re-installs the Esc monitor when it attaches to a
    /// window, so a nil window during SwiftUI creation can't leave the
    /// showcase without dismissal.
    private final class ShowcaseEscapeHostView: NSView {
        var onMoveToWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.onMoveToWindow?(self.window)
        }
    }

    @MainActor
    final class Coordinator {
        var onEscape: @MainActor () -> Void
        private weak var window: NSWindow?
        private var monitor: Any?

        init(onEscape: @escaping @MainActor () -> Void) {
            self.onEscape = onEscape
        }

        func install(window: NSWindow?) {
            self.window = window
            guard self.monitor == nil, window != nil else { return }
            self.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      event.keyCode == 53,
                      event.window === self.window,
                      self.window?.isKeyWindow == true
                else {
                    return event
                }
                self.onEscape()
                return nil
            }
        }

        func uninstall() {
            if let monitor = self.monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
