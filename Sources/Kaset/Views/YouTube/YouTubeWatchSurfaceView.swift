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
        for subview in self.subviews where subview is WKWebView {
            subview.frame = self.bounds.insetBy(dx: -1.5, dy: -1.5)
        }
    }
}
