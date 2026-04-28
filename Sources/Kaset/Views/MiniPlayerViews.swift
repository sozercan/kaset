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
