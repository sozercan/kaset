import SwiftUI
import WebKit

// MARK: - YouTubeWatchSurfaceView

/// Hosts the extracted YouTube video surface (the watch WebView) inside a
/// native view. Used by both the inline WatchView and the floating window;
/// whichever is on screen reparents the singleton WebView into itself.
struct YouTubeWatchSurfaceView: NSViewRepresentable {
    func makeNSView(context _: Context) -> YouTubeWatchContainerView {
        let container = YouTubeWatchContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ nsView: YouTubeWatchContainerView, context _: Context) {
        YouTubeWatchWebView.shared.ensureInHierarchy(container: nsView)
    }
}

// MARK: - YouTubeWatchContainerView

/// Custom NSView that keeps the WebView sized with the container.
final class YouTubeWatchContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.postsFrameChangedNotifications = true
        self.wantsLayer = true
        self.layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // Overscan the WebView slightly: fractional-point rounding between
        // SwiftUI's aspect-fitted frame and the page's 100vw video leaves
        // hairline black slivers at the edges otherwise. The container's
        // layer clips the overflow.
        for subview in self.subviews where subview is WKWebView {
            subview.frame = self.bounds.insetBy(dx: -1.5, dy: -1.5)
        }
    }
}
