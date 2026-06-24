import SwiftUI
import WebKit

// MARK: - VideoPlayerWindow

/// Floating window for video playback.
struct VideoPlayerWindow: View {
    @Environment(PlayerService.self) private var playerService

    @State private var isHovering = false

    var body: some View {
        // The Window controls the aspect ratio and min size;
        // using .fit here can cause the webview to shrink/be letterboxed incorrectly during fast resize.
        VideoWebViewContainer()
            .background(.black)
            // Standard macOS video idiom: double-click toggles fullscreen.
            .onTapGesture(count: 2) {
                VideoWindowController.shared.toggleFullscreen()
            }
            .overlay(alignment: .topTrailing) {
                self.fullscreenButton
                    .padding(12)
                    .opacity(self.isHovering ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: self.isHovering)
            }
            .onHover { hovering in
                self.isHovering = hovering
            }
            .accessibilityIdentifier(AccessibilityID.VideoWindow.container)
    }

    /// Hover-revealed control that enters/exits macOS fullscreen. Mirrors the
    /// "Full view" affordance on the YouTube side; the green traffic-light
    /// button and ⌃⌘F do the same thing thanks to `.fullScreenPrimary`.
    private var fullscreenButton: some View {
        Button {
            VideoWindowController.shared.toggleFullscreen()
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.55), in: .circle)
        }
        .buttonStyle(.plain)
        .help(String(localized: "Enter Full Screen"))
        .accessibilityLabel(String(localized: "Toggle full screen video"))
        // Note: the ⌃⌘F key equivalent lives on the app's Playback menu
        // (KasetApp), not here — this window is shown non-key (orderFront), so a
        // shortcut attached to this button would not fire until it gained focus.
    }
}

// MARK: - VideoWebViewContainer

/// NSViewRepresentable container for the video WebView.
struct VideoWebViewContainer: NSViewRepresentable {
    func makeNSView(context _: Context) -> VideoContainerView {
        DiagnosticsLogger.player.info("VideoWebViewContainer.makeNSView called")
        let container = VideoContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ nsView: VideoContainerView, context _: Context) {
        DiagnosticsLogger.player.debug("VideoWebViewContainer.updateNSView called")
        // Reparent the WebView into this container for video display
        SingletonPlayerWebView.shared.ensureInHierarchy(container: nsView)
    }
}

// MARK: - VideoContainerView

/// Custom NSView that observes frame changes and re-injects CSS.
final class VideoContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.frameDidChange),
            name: NSView.frameDidChangeNotification,
            object: self
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var refreshTask: Task<Void, Never>?

    @objc private func frameDidChange(_: Notification) {
        // Debounce slightly to prevent JS overload during continuous resize
        self.refreshTask?.cancel()
        self.refreshTask = Task { @MainActor in
            try? await Task.sleep(for: .nanoseconds(16_666_666)) // ~60fps
            if !Task.isCancelled, SingletonPlayerWebView.shared.displayMode == .video {
                SingletonPlayerWebView.shared.refreshVideoModeCSS()
            }
        }
    }

    deinit {
        self.refreshTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Preview

#Preview {
    VideoPlayerWindow()
        .environment(PlayerService())
        .frame(width: 480, height: 270)
}
