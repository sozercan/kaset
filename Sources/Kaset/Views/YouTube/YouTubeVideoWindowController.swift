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

    /// When fullscreen was entered from the inline watch view, exiting it
    /// docks the video back inline instead of leaving the small pop-out.
    private var returnInlineOnExitFullscreen = false

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

        let defaultRect = NSRect(x: 0, y: 0, width: 640, height: 360)
        let window = NSWindow(
            contentRect: defaultRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
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
        // fullScreenPrimary so the green traffic light enters fullscreen
        // (not just zoom).
        window.collectionBehavior = [.fullScreenPrimary]
        // Lock resizing to the video's aspect ratio so the surface can't be
        // misshapen (controls overlay inside the video, so content == video).
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        // Generous floor: the full player bar needs the width, and very
        // small WebView surfaces have crashed during live resizes.
        window.contentMinSize = NSSize(width: 512, height: 288)
        window.backgroundColor = .black
        window.setFrameAutosaveName(self.frameAutosaveKey)
        window.identifier = NSUserInterfaceItemIdentifier(AccessibilityID.YouTubeContent.videoWindow)

        if !window.setFrameUsingName(self.frameAutosaveKey) {
            self.positionAtDefaultLocation(window: window)
        }
        // Saved frames from earlier layouts may not be 16:9; the aspect lock
        // only constrains user resizes, so normalize the content explicitly.
        var contentSize = window.contentRect(forFrameRect: window.frame).size
        contentSize.width = max(contentSize.width, 512)
        let expectedHeight = contentSize.width * 9 / 16
        if abs(contentSize.height - expectedHeight) > 1 || contentSize.width < 512 {
            window.setContentSize(NSSize(width: contentSize.width, height: expectedHeight))
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.windowDidEnterFullScreen),
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.windowDidExitFullScreen),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
    }

    @objc private func windowDidEnterFullScreen(_: Notification) {
        self.youtubePlayerService?.isWindowFullscreen = true
    }

    @objc private func windowDidExitFullScreen(_: Notification) {
        self.youtubePlayerService?.isWindowFullscreen = false
        if self.returnInlineOnExitFullscreen {
            self.returnInlineOnExitFullscreen = false
            self.youtubePlayerService?.requestPopIn()
        }
    }

    /// Toggles fullscreen on the floating window.
    /// - Parameter returnInlineOnExit: when true (fullscreen entered from
    ///   the inline watch view), exiting fullscreen docks the video back
    ///   into the app instead of leaving the pop-out window around.
    func toggleFullscreen(returnInlineOnExit: Bool = false) {
        if returnInlineOnExit, self.window?.styleMask.contains(.fullScreen) != true {
            self.returnInlineOnExitFullscreen = true
        }
        self.window?.toggleFullScreen(nil)
    }

    /// Shows/hides the traffic lights with the hover overlay so the video
    /// is chrome-free when the cursor is elsewhere.
    func setWindowChromeVisible(_ visible: Bool) {
        guard let window = self.window else { return }
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(buttonType)?.animator().alphaValue = visible ? 1 : 0
        }
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
        self.youtubePlayerService?.isWindowFullscreen = false
        self.returnInlineOnExitFullscreen = false
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

/// Floating window content: corner-to-corner video with hover-revealed
/// chrome — a compact Liquid Glass bar over the bottom of the video and a
/// small glass backing under the traffic lights. Cursor leaves → all
/// chrome fades out.
private struct YouTubeVideoWindowContent: View {
    @Environment(YouTubePlayerService.self) private var youtubePlayer

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .bottom) {
                YouTubeWatchSurfaceView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if self.isHovering {
                    // The full player bar — same items as the main window.
                    YouTubePlayerBar()
                        .transition(.opacity)
                }
            }
        }
        .background(.black)
        .ignoresSafeArea()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                self.isHovering = hovering
            }
            YouTubeVideoWindowController.shared.setWindowChromeVisible(hovering)
        }
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let videoWindow = "youtubeContent.videoWindow"
}
