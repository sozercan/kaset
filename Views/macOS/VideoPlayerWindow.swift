import SwiftUI
import WebKit

// MARK: - VideoPlayerWindow

/// Floating Picture-in-Picture style window for video playback.
@available(macOS 26.0, *)
struct VideoPlayerWindow: View {
    @Environment(PlayerService.self) private var playerService

    var body: some View {
        // Video content (WebView container) with native HTML5 controls
        VideoWebViewContainer()
            .background(.black)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(minWidth: 320, minHeight: 180)
    }
}

// MARK: - VideoWebViewContainer

/// NSViewRepresentable container for the video WebView.
struct VideoWebViewContainer: NSViewRepresentable {
    func makeNSView(context _: Context) -> VideoContainerView {
        let container = VideoContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ nsView: VideoContainerView, context _: Context) {
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

    @objc private func frameDidChange(_: Notification) {
        // Debounce: re-inject CSS after resize settles
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(self.reinjectCSS), object: nil)
        self.perform(#selector(self.reinjectCSS), with: nil, afterDelay: 0.1)
    }

    @objc private func reinjectCSS() {
    // Ensure we're on the main actor since SingletonPlayerWebView is @MainActor
    Task { @MainActor in
      // Re-inject video mode CSS to fix layout after resize
      if SingletonPlayerWebView.shared.displayMode == .video {
        SingletonPlayerWebView.shared.refreshVideoModeCSS()
      }
    }
  }

    deinit {
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview {
    VideoPlayerWindow()
        .environment(PlayerService())
        .frame(width: 480, height: 270)
}
