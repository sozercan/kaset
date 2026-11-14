import SwiftUI
import WebKit

// MARK: - VideoPlayerWindow

/// Floating window for video playback.
struct VideoPlayerWindow: View {
    @Environment(PlayerService.self) private var playerService

    var body: some View {
        // The Window controls the aspect ratio and min size;
        // using .fit here can cause the webview to shrink/be letterboxed incorrectly during fast resize.
        VideoWebViewContainer(videoId: self.playerService.pendingPlayVideoId)
            .background(.black)
            .accessibilityIdentifier(AccessibilityID.VideoWindow.container)
    }
}

// MARK: - VideoWebViewContainer

/// NSViewRepresentable container for the video WebView.
struct VideoWebViewContainer: NSViewRepresentable {
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(PlayerService.self) private var playerService
    @Environment(AuthService.self) private var authService

    let videoId: String?
    var isShowcase = false

    func makeNSView(context _: Context) -> VideoContainerView {
        DiagnosticsLogger.player.info("VideoWebViewContainer.makeNSView called")
        let container = VideoContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        self.attachPlayerWebView(to: container)
        return container
    }

    func updateNSView(_ nsView: VideoContainerView, context _: Context) {
        DiagnosticsLogger.player.debug("VideoWebViewContainer.updateNSView called")
        self.attachPlayerWebView(to: nsView)
    }

    private func attachPlayerWebView(to container: VideoContainerView) {
        guard self.playerService.playbackViewHost == (self.isShowcase ? .showcase : .videoWindow) else { return }
        _ = SingletonPlayerWebView.shared.getWebView(
            webKitManager: self.webKitManager,
            playerService: self.playerService,
            usesCookieFreeDataStore: self.authService.shouldUseCookieFreePlaybackDataStore
        )
        SingletonPlayerWebView.shared.ensureInHierarchy(container: container)
        if SingletonPlayerWebView.shared.displayMode != .video {
            self.playerService.videoWindowDidOpen()
        }
        SingletonPlayerWebView.shared.updateDisplayMode(.video)

        // Click-to-pause belongs to Kaset: the surface swallows clicks that would
        // otherwise double-fire through YouTube's own video and overlay controls.
        container.clickSurface.isHidden = false
        container.clickSurface.onClick = { [weak playerService] in
            guard let playerService,
                  SingletonPlayerWebView.shared.displayMode == .video
            else { return }
            Task { await playerService.playPause() }
        }

        if let videoId = self.videoId,
           self.playerService.shouldAutoloadPendingVideo,
           SingletonPlayerWebView.shared.currentVideoId != videoId
        {
            SingletonPlayerWebView.shared.loadVideo(videoId: videoId)
        }
    }
}

// MARK: - VideoContainerView

/// Custom NSView that observes frame changes and re-injects CSS.
final class VideoContainerView: NSView {
    /// Transparent surface above the WebView that owns click-to-pause while the
    /// video-mode CSS hides all of YouTube's chrome.
    let clickSurface = VideoClickSurfaceView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.frameDidChange),
            name: NSView.frameDidChangeNotification,
            object: self
        )
        self.clickSurface.isHidden = true
        self.clickSurface.frame = self.bounds
        self.clickSurface.autoresizingMask = [.width, .height]
        super.addSubview(self.clickSurface)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Keep the click surface above the re-parented WebView.
    override func addSubview(_ subview: NSView) {
        super.addSubview(subview)
        guard subview !== self.clickSurface else { return }
        super.addSubview(self.clickSurface)
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

// MARK: - VideoClickSurfaceView

/// Swallows mouse clicks over the video so the page's own click-to-toggle and
/// overlay button cannot double-fire; a click pauses or resumes exactly once.
final class VideoClickSurfaceView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with _: NSEvent) {
        self.onClick?()
    }

    /// Right-click must also stay off the page: YouTube's own context menu
    /// would otherwise appear in video mode.
    override func rightMouseDown(with _: NSEvent) {}

    override func menu(for _: NSEvent) -> NSMenu? {
        nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func isAccessibilityElement() -> Bool {
        false
    }
}

// MARK: - Preview

#Preview {
    VideoPlayerWindow()
        .environment(PlayerService())
        .environment(WebKitManager.shared)
        .environment(AuthService())
        .frame(width: 480, height: 270)
}
