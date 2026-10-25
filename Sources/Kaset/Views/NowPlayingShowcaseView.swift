import AppKit
import SwiftUI

// MARK: - NowPlayingShowcaseView

/// Full-window now-playing showcase overlay, modeled on the YouTube Music watch
/// page and Apple Music's expanded player: ambient glow derived from the
/// artwork, large rounded artwork with a soft shadow, big track title/artist,
/// and the "Up Next" queue in a resizable, collapsible trailing column.
///
/// Hosted by `MainWindow` over the whole window with the player bar layered
/// ABOVE it, so the glass bar and the ambient backdrop read as one continuous
/// surface (no seam) and every bar control stays live while the showcase is
/// open. The bar is the single transport — play/pause, seek, shuffle/repeat,
/// volume, like/dislike, lyrics/queue/video toggles; this view deliberately
/// adds no duplicate transport controls. Tapping the exposed backdrop, the
/// chevron, the bar's track title, or Esc dismisses it.
struct NowPlayingShowcaseView: View {
    /// Queue column resize bounds, following the lyrics panel's limits.
    private static let queuePanelMinWidth: CGFloat = 300
    private static let queuePanelMaxWidth: CGFloat = 560
    private static let defaultQueuePanelWidth: CGFloat = 340

    @Environment(PlayerService.self) private var playerService
    @State private var settings = SettingsManager.shared

    @State private var isQueueCollapsed = false
    @State private var queuePanelWidth = SettingsManager.shared.nowPlayingQueueWidth.map {
        min(max(CGFloat($0), NowPlayingShowcaseView.queuePanelMinWidth), NowPlayingShowcaseView.queuePanelMaxWidth)
    } ?? NowPlayingShowcaseView.defaultQueuePanelWidth
    @State private var queueDragStartWidth: CGFloat?
    @State private var isHoveringQueueResize = false

    var body: some View {
        GeometryReader { proxy in
            let artworkSize = self.artworkSize(for: proxy.size)

            ZStack {
                if let track = self.playerService.currentTrack {
                    self.ambientBackdrop(for: track)
                }

                // Dismisses on tap. The player bar that MainWindow layers above
                // this surface is hit first, so none of its controls are blocked.
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: self.close)

                HStack(alignment: .center, spacing: 32) {
                    self.mainColumn(artworkSize: artworkSize)
                        .frame(maxWidth: .infinity)

                    if !self.isQueueCollapsed {
                        self.queuePanel
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.leading, 56)
                .padding(.trailing, 20)
                // Clears the player bar layered above the showcase's bottom edge.
                .padding(.bottom, 76)
            }
        }
        .background {
            ShowcaseEscapeKeyMonitor(onEscape: self.close)
        }
    }

    // MARK: - Layout

    private func mainColumn(artworkSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                self.closeButton
                Spacer()

                // Collapse/expand the Up Next column; the artwork column takes the width.
                self.queueToggleButton
            }
            .padding(.top, 16)

            Spacer()

            if let track = self.playerService.currentTrack {
                self.trackSection(track, artworkSize: artworkSize)
            } else {
                Text("Not Playing")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private func trackSection(_ track: Song, artworkSize: CGFloat) -> some View {
        VStack(spacing: 28) {
            ShowcaseArtworkView(song: track, size: artworkSize, cornerRadius: 16)
                .shadow(color: .black.opacity(0.35), radius: 32, y: 16)

            VStack(spacing: 6) {
                Text(track.title)
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(track.artistsDisplay.isEmpty ? String(localized: "Unknown Artist") : track.artistsDisplay)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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

    /// Caps the artwork so the title fits and the column clears the player bar
    /// layered above the showcase's bottom edge.
    private func artworkSize(for size: CGSize) -> CGFloat {
        let queueAllowance: CGFloat = self.isQueueCollapsed ? 0 : self.queuePanelWidth + 32
        let heightBudget = size.height - 250 // close row, 2-line title/artist, bar clearance
        let widthBudget = size.width - 76 - queueAllowance // leading/trailing padding + queue column
        return max(160, min(400, heightBudget, widthBudget))
    }

    // MARK: - Queue Panel

    private var queuePanel: some View {
        QueueView(width: self.queuePanelWidth)
            .overlay(alignment: .leading) { self.queueResizeHandle }
    }

    /// Leading-edge drag handle, same interaction as the lyrics panel's. The
    /// hit area covers the full 32pt column gap so the cursor and grip
    /// indicator appear right at the gap's edge; the visual grip stays on the
    /// 10pt strip inside the panel.
    private var queueResizeHandle: some View {
        Color.clear
            .frame(width: 32)
            .padding(.leading, -22)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(self.isHoveringQueueResize ? 0.6 : 0))
                    .frame(width: 3, height: 40)
                    .padding(.leading, 25)
            }
            .onHover { hovering in
                self.isHoveringQueueResize = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if self.queueDragStartWidth == nil {
                            self.queueDragStartWidth = self.queuePanelWidth
                        }
                        let start = self.queueDragStartWidth ?? self.queuePanelWidth
                        // The handle sits on the column's leading edge, so
                        // dragging left widens it.
                        self.queuePanelWidth = min(
                            max(start - value.translation.width, Self.queuePanelMinWidth),
                            Self.queuePanelMaxWidth
                        )
                    }
                    .onEnded { _ in
                        if let start = self.queueDragStartWidth, self.queuePanelWidth != start {
                            self.settings.nowPlayingQueueWidth = Double(self.queuePanelWidth)
                        }
                        self.queueDragStartWidth = nil
                    }
            )
    }

    private var queueToggleButton: some View {
        PlayerBarIconButton(
            action: {
                withAnimation(AppAnimation.standard) {
                    self.isQueueCollapsed.toggle()
                }
            },
            accessibilityLabel: self.isQueueCollapsed ? String(localized: "Show Queue") : String(localized: "Hide Queue"),
            icon: {
                Image(systemName: self.isQueueCollapsed ? "chevron.left" : "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        )
    }

    // MARK: - Dismissal

    private var closeButton: some View {
        PlayerBarIconButton(
            action: self.close,
            accessibilityLabel: String(localized: "Close"),
            icon: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        )
    }

    private func close() {
        withAnimation(AppAnimation.standard) {
            self.playerService.showNowPlayingShowcase = false
        }
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
