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

    /// Floor for the video content area. Below roughly this size the macOS 26
    /// `NSHostingView` safe-area corner-inset recompute can raise an uncaught
    /// `NSException` during the display-cycle commit and abort the app, so the
    /// resize guard never lets the content shrink past it.
    private static let minContentSize = NSSize(width: 512, height: 288)

    /// Enforces the 16:9 ratio and the `minContentSize` floor on every resize.
    /// Strong reference because `NSWindow.delegate` is weak; kept for the
    /// window's lifetime and torn down in `performCleanup`.
    private var resizeGuard: YouTubeVideoWindowResizeGuard?

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
        // Aspect + floor are enforced by the resize-guard delegate below, NOT
        // by contentAspectRatio. With both contentAspectRatio and
        // contentMinSize set, AppKit honors the aspect lock on the dragged axis
        // during live resize and lets the OTHER axis slip below the floor; the
        // resulting degenerate content rect makes the macOS 26 NSHostingView
        // safe-area corner-inset update raise an uncaught NSException in the
        // display-cycle commit (SIGABRT). A windowWillResize clamp is the single
        // sizing authority, so the two constraints can't fight.
        let resizeGuard = YouTubeVideoWindowResizeGuard(minContentSize: Self.minContentSize)
        self.resizeGuard = resizeGuard
        window.delegate = resizeGuard
        // Harmless backstop now that nothing competes with it.
        window.contentMinSize = Self.minContentSize
        window.backgroundColor = .black
        window.setFrameAutosaveName(self.frameAutosaveKey)
        window.identifier = NSUserInterfaceItemIdentifier(AccessibilityID.YouTubeContent.videoWindow)

        if !window.setFrameUsingName(self.frameAutosaveKey) {
            self.positionAtDefaultLocation(window: window)
        }
        // A saved frame from an earlier layout may not be 16:9 (or may be below
        // the floor); windowWillResize only fires for interactive resizes, so
        // normalize the restored frame explicitly through the same clamp.
        let currentContent = window.contentRect(forFrameRect: window.frame).size
        let normalized = YouTubeVideoWindowResizeGuard.normalizedContentSize(
            for: currentContent,
            minContentSize: Self.minContentSize
        )
        if abs(currentContent.width - normalized.width) > 1
            || abs(currentContent.height - normalized.height) > 1
        {
            window.setContentSize(normalized)
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
        // Remove the fullscreen observers registered in show() so they don't
        // stack on the shared singleton across show/close cycles. (The willClose
        // observer is removed on the close paths before cleanup runs.) Scoped to
        // the window object, mirroring how show() registered them.
        if let window = self.window {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didEnterFullScreenNotification,
                object: window
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didExitFullScreenNotification,
                object: window
            )
        }
        self.window?.delegate = nil
        self.resizeGuard = nil
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

// MARK: - YouTubeVideoWindowResizeGuard

/// Window delegate that keeps the floating video window at 16:9 and never lets
/// it shrink below a safe floor.
///
/// Replaces `NSWindow.contentAspectRatio` + `contentMinSize`: when both are
/// set, AppKit reconciles the aspect lock on the dragged axis during a live
/// resize and lets the other axis slip below the floor. The degenerate content
/// rect then makes the macOS 26 `NSHostingView` safe-area corner-inset recompute
/// raise an uncaught `NSException` inside the display-cycle commit, aborting the
/// app. Clamping every proposed frame in `windowWillResize(_:to:)` — before the
/// geometry is applied — keeps a single sizing authority, so nothing competes.
@MainActor
final class YouTubeVideoWindowResizeGuard: NSObject, NSWindowDelegate {
    private let minContentSize: NSSize

    init(minContentSize: NSSize) {
        self.minContentSize = minContentSize
        super.init()
    }

    /// Floors a proposed content size and snaps it to 16:9. Pure function so
    /// both interactive resizes and programmatic frame restores share it.
    ///
    /// `current` lets the clamp follow whichever axis the user is dragging: a
    /// vertical-edge drag changes height but not width, so deriving width from
    /// the changed height keeps that drag responsive instead of snapping back.
    /// Pass `nil` (the default) to always drive off width.
    static func normalizedContentSize(
        for proposed: NSSize,
        minContentSize: NSSize,
        current: NSSize? = nil
    ) -> NSSize {
        // Pick the driving axis: the one that changed more relative to `current`
        // (width by default). Height-driven keeps vertical-edge drags working.
        let heightDriven: Bool = if let current {
            abs(proposed.height - current.height) > abs(proposed.width - current.width)
        } else {
            false
        }

        if heightDriven {
            let height = max(proposed.height, minContentSize.height)
            var width = (height * 16 / 9).rounded()
            if width < minContentSize.width {
                width = minContentSize.width
            }
            return NSSize(width: width, height: height)
        }

        let width = max(proposed.width, minContentSize.width)
        var height = (width * 9 / 16).rounded()
        if height < minContentSize.height {
            height = minContentSize.height
        }
        return NSSize(width: width, height: height)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // Never reshape a fullscreen transition: the animation drives the window
        // to screen size (far above the floor), and returning a width-derived
        // 16:9 size would distort it. Only interactive/standard resizes need the
        // clamp.
        guard !sender.styleMask.contains(.fullScreen) else { return frameSize }
        // frameSize is a FRAME size; convert to content, clamp, convert back so
        // the titlebar inset is preserved. Pass the current content size so a
        // vertical-edge drag (height changes, width doesn't) follows the height.
        let proposedFrame = NSRect(origin: .zero, size: frameSize)
        let proposedContent = sender.contentRect(forFrameRect: proposedFrame).size
        let currentContent = sender.contentRect(forFrameRect: sender.frame).size
        let clampedContent = Self.normalizedContentSize(
            for: proposedContent,
            minContentSize: self.minContentSize,
            current: currentContent
        )
        let clampedFrame = sender.frameRect(forContentRect: NSRect(origin: .zero, size: clampedContent))
        return clampedFrame.size
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

    /// Height of the top strip that moves the window. Generous enough to be
    /// an easy grab target; the top of the video carries no YouTube controls
    /// (the scrubber lives at the bottom), so it costs no native click area.
    private static let dragStripHeight: CGFloat = 36

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

            // Top drag strip: the corner-to-corner WebView reports
            // mouseDownCanMoveWindow == false and swallows mouseDown, so the
            // window's isMovableByWindowBackground is dead everywhere the
            // WebView covers — leaving only the hidden titlebar sliver to grab.
            // This native strip sits above the WebView and moves the window
            // explicitly via NSWindow.performDrag.
            WindowDragHandle()
                .frame(maxWidth: .infinity)
                .frame(height: Self.dragStripHeight)
                .overlay(alignment: .top) {
                    if self.isHovering {
                        // Subtle grab affordance so the drag region is
                        // discoverable without cluttering the chrome-free look.
                        Capsule()
                            .fill(.white.opacity(0.35))
                            .frame(width: 36, height: 5)
                            .padding(.top, 7)
                            .transition(.opacity)
                            .allowsHitTesting(false)
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

// MARK: - WindowDragHandle

/// Transparent native strip that lets the user move the floating window by
/// dragging along the top. The hosted WebView reports
/// `mouseDownCanMoveWindow == false` and consumes `mouseDown`, defeating the
/// window's `isMovableByWindowBackground` everywhere it covers; this strip sits
/// above the WebView and drives the move explicitly through
/// `NSWindow.performDrag(with:)`. Scoped to the floating window only — the
/// shared `YouTubeWatchSurfaceView` is untouched.
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        WindowDragNSView()
    }

    func updateNSView(_: NSView, context _: Context) {}
}

// MARK: - WindowDragNSView

/// Backing view for `WindowDragHandle`.
private final class WindowDragNSView: NSView {
    /// Take `mouseDown` ourselves instead of letting AppKit's background-drag
    /// heuristics intercept it, so the move is driven deterministically.
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    /// Drag even when the floating window is not key — it is ordered front
    /// without stealing focus, so a first click must move it, not just activate.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        // Preserve the standard titlebar gesture: a double-click performs the
        // user's configured "double-click a window's title bar to" action
        // (Zoom / Minimize / None); a single click starts the window drag.
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize":
                self.window?.miniaturize(nil)
            case "None":
                break
            default: // "Maximize" (zoom) is the macOS default.
                self.window?.performZoom(nil)
            }
        } else {
            self.window?.performDrag(with: event)
        }
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let videoWindow = "youtubeContent.videoWindow"
}
