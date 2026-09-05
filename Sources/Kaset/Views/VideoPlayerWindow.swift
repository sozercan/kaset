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
        _ = SingletonPlayerWebView.shared.getWebView(
            webKitManager: self.webKitManager,
            playerService: self.playerService,
            usesCookieFreeDataStore: self.authService.shouldUseCookieFreePlaybackDataStore
        )
        SingletonPlayerWebView.shared.ensureInHierarchy(container: container)
        SingletonPlayerWebView.shared.updateDisplayMode(.video)

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
        .environment(WebKitManager.shared)
        .environment(AuthService())
        .frame(width: 480, height: 270)
}
