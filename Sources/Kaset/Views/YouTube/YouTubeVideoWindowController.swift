import AppKit
import SwiftUI

// MARK: - YouTubeVideoWindowController

/// Manages the floating window that hosts the YouTube video surface when
/// it is popped out of the inline watch view (or when the user navigates
/// away while a video plays).
///
/// Parallels `VideoWindowController` (music video mode); kept separate so
/// the music path stays untouched.
@MainActor
final class YouTubeVideoWindowController {
    static let shared = YouTubeVideoWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    private weak var youtubePlayerService: YouTubePlayerService?
    private var isClosing = false
    private let frameAutosaveKey = "KasetYouTubeVideoWindow"

    private init() {}

    /// Shows the floating window hosting the video surface.
    func show(youtubePlayerService: YouTubePlayerService) {
        self.youtubePlayerService = youtubePlayerService

        if let existingWindow = self.window {
            self.isClosing = false
            existingWindow.title = youtubePlayerService.currentVideo?.title ?? "YouTube"
            existingWindow.orderFront(nil)
            return
        }

        let contentView = YouTubeVideoWindowContent()
            .environment(youtubePlayerService)

        let hostingView = NSHostingView(rootView: AnyView(contentView))
        self.hostingView = hostingView

        let defaultRect = NSRect(x: 0, y: 0, width: 480, height: 300)
        let window = NSWindow(
            contentRect: defaultRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.title = youtubePlayerService.currentVideo?.title ?? "YouTube"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Lock resizing to the video's aspect ratio so the surface can't be
        // misshapen (controls overlay inside the video, so content == video).
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.minSize = NSSize(width: 320, height: 180)
        window.backgroundColor = .black
        window.setFrameAutosaveName(self.frameAutosaveKey)
        window.identifier = NSUserInterfaceItemIdentifier(AccessibilityID.YouTubeContent.videoWindow)

        if !window.setFrameUsingName(self.frameAutosaveKey) {
            self.positionAtDefaultLocation(window: window)
        }

        window.orderFront(nil)
        self.window = window
        self.isClosing = false

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.windowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    /// Toggles fullscreen on the floating window.
    func toggleFullscreen() {
        self.window?.toggleFullScreen(nil)
    }

    /// Closes the window programmatically (e.g. when docking back inline).
    func close() {
        guard !self.isClosing else { return }
        guard let window = self.window else { return }

        self.isClosing = true
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        window.saveFrame(usingName: self.frameAutosaveKey)
        self.performCleanup()
        window.close()
    }

    /// Red-X close: closing the floating window stops video playback.
    @objc private func windowWillClose(_ notification: Notification) {
        guard !self.isClosing else { return }
        self.isClosing = true

        if let window = notification.object as? NSWindow {
            window.saveFrame(usingName: self.frameAutosaveKey)
        }

        let service = self.youtubePlayerService
        self.performCleanup()

        if service?.surfaceLocation == .floating {
            service?.stop()
        }
    }

    private func performCleanup() {
        self.window = nil
        self.hostingView = nil
        self.isClosing = false
    }

    private func positionAtDefaultLocation(window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size
        let padding: CGFloat = 40

        let origin = NSPoint(
            x: screenFrame.maxX - windowSize.width - padding,
            y: screenFrame.maxY - windowSize.height - padding
        )
        window.setFrameOrigin(origin)
    }
}

// MARK: - YouTubeVideoWindowContent

/// Floating window content: just the video surface (aspect-locked window).
/// Playback is controlled from the player bar in the main window.
private struct YouTubeVideoWindowContent: View {
    @Environment(YouTubePlayerService.self) private var youtubePlayer

    var body: some View {
        YouTubeWatchSurfaceView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let videoWindow = "youtubeContent.videoWindow"
}
