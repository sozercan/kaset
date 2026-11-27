import SwiftUI
import WebKit

struct YouTubeWatchSurfaceView: NSViewRepresentable {
    @Environment(YouTubePlayerService.self) private var youtubePlayer

    let expectedVideoId: String?

    init(expectedVideoId: String? = nil) {
        self.expectedVideoId = expectedVideoId
    }

    func makeNSView(context _: Context) -> YouTubeWatchContainerView {
        let container = YouTubeWatchContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ nsView: YouTubeWatchContainerView, context _: Context) {
        YouTubeWatchWebView.shared.ensureInHierarchy(
            container: nsView,
            expectedVideoId: self.expectedVideoId,
            selectedVideoId: self.youtubePlayer.currentVideo?.videoId
        )
    }
}

@MainActor
enum YouTubeWatchSurfaceAttachment {
    @discardableResult
    static func claim(
        surface: NSView,
        in container: NSView,
        expectedVideoId: String?,
        currentVideoId: String?
    ) -> Bool {
        if let expectedVideoId, expectedVideoId != currentVideoId {
            return false
        }
        guard surface.superview !== container else { return true }
        surface.removeFromSuperview()
        container.addSubview(surface)
        return true
    }
}

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
        let alignedFrame = self.alignedWebViewFrame()
        for subview in self.subviews where subview is WKWebView {
            subview.frame = alignedFrame
        }
    }

    func alignedWebViewFrame() -> NSRect {
        guard self.bounds.width > 0, self.bounds.height > 0 else { return .zero }
        if self.window != nil {
            return self.backingAlignedRect(self.bounds, options: .alignAllEdgesInward)
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return Self.pixelAlignedBounds(self.bounds, backingScaleFactor: scale)
    }

    static func pixelAlignedBounds(_ bounds: NSRect, backingScaleFactor: CGFloat) -> NSRect {
        let scale = max(backingScaleFactor, 1.0)
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let minX = ceil(bounds.minX * scale) / scale
        let minY = ceil(bounds.minY * scale) / scale
        let maxX = floor(bounds.maxX * scale) / scale
        let maxY = floor(bounds.maxY * scale) / scale
        guard maxX > minX, maxY > minY else { return .zero }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
