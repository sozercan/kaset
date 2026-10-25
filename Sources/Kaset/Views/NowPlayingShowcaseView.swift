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
            let artworkSize = NowPlayingShowcaseLayout.artworkSize(in: proxy.size, panelWidth: self.playerService.nowPlayingPanel == nil ? nil : panelWidth)

            ZStack {
                if let track = self.playerService.currentTrack {
                    self.ambientBackdrop(for: track)
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
                        self.mainColumn(artworkSize: artworkSize)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if let panel = self.playerService.nowPlayingPanel {
                            self.detailPanel(panel, width: panelWidth)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 76)
            }
        }
        .background { ShowcaseEscapeKeyMonitor(onEscape: self.close) }
    }

    // MARK: - Layout

    @ViewBuilder
    private func mainColumn(artworkSize: CGFloat) -> some View {
        if let track = self.playerService.currentTrack {
            VStack(spacing: 20) {
                ShowcaseArtworkView(song: track, size: artworkSize, cornerRadius: 16)
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 12)

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

    private func ambientBackdrop(for track: Song) -> some View {
        AmbientVideoBackdrop(
            videoId: track.videoId,
            thumbnailURL: track.thumbnailURL?.highQualityThumbnailURL ?? track.fallbackThumbnailURL,
            style: .glow,
            liveFraction: nil,
            storyboardSpec: nil
        )
        .ignoresSafeArea()
    }

    // MARK: - Panel

    private var panelControls: some View {
        HStack(spacing: 4) {
            ForEach(PlayerService.NowPlayingPanel.allCases, id: \.self) { panel in
                self.tabButton(panel)
            }
            Divider().frame(height: 18).padding(.horizontal, 6)
            MiniPlayerToggleButton(player: self.playerService, size: 36)
            self.collapseButton
        }
    }

    private func tabButton(_ panel: PlayerService.NowPlayingPanel) -> some View {
        let isSelected = self.playerService.nowPlayingPanel == panel
        return Button {
            HapticService.toggle()
            // Animate only content changes; opening a collapsed panel must not tween the artwork's size.
            withAnimation(self.playerService.nowPlayingPanel == nil || self.reduceMotion ? nil : .easeOut(duration: 0.18)) {
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

    private var collapseButton: some View {
        PlayerBarIconButton(
            action: {
                self.playerService.nowPlayingPanel = self.playerService.nowPlayingPanel == nil ? .queue : nil
            },
            size: 36,
            accessibilityLabel: self.playerService.nowPlayingPanel == nil ? String(localized: "Show Queue") : String(localized: "Hide Panel"),
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
        withAnimation(self.reduceMotion ? nil : .easeOut(duration: 0.18)) {
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

    static func artworkSize(in size: CGSize, panelWidth: CGFloat?) -> CGFloat {
        let panelAllowance = panelWidth.map { $0 + 24 } ?? 0
        return max(120, min(400, size.height - 264, size.width - 48 - panelAllowance))
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

    func body(content: Content) -> some View {
        content
            .opacity(self.isHovered ? 1.0 : 0.88)
            .animation(AppAnimation.quick, value: self.isHovered)
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
