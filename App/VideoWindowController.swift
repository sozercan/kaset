import AppKit
import SwiftUI

// MARK: - VideoWindowController

/// Manages the floating video window.
@available(macOS 26.0, *)
@MainActor
final class VideoWindowController {
    static let shared = VideoWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    private let logger = DiagnosticsLogger.player

    /// Reference to PlayerService to sync showVideo state
    private weak var playerService: PlayerService?

    /// Flag to prevent re-entrant close handling
    private var isClosing = false

    // Corner snapping
    enum Corner: Int {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private var currentCorner: Corner = .bottomRight

    private init() {
        self.loadCorner()
    }

    /// Shows the video window.
    func show(
        playerService: PlayerService,
        webKitManager: WebKitManager
    ) {
        self.logger.debug("VideoWindowController.show() called")

        // Store reference to sync state on close
        self.playerService = playerService

        // Start grace period to prevent race condition when video element is moved
        playerService.videoWindowDidOpen()

        if let existingWindow = self.window {
            // Window exists - just bring it to front
            self.logger.debug("Window already exists, bringing to front")
            self.isClosing = false // Reset in case of interrupted close
            existingWindow.makeKeyAndOrderFront(nil)
            // Ensure video mode is active
            SingletonPlayerWebView.shared.updateDisplayMode(.video)
            return
        }

        self.logger.info("Creating new video window")

        let contentView = VideoPlayerWindow()
            .environment(playerService)
            .environment(webKitManager)

        let hostingView = NSHostingView(rootView: AnyView(contentView))
        self.hostingView = hostingView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.title = "Video"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // Normal window level (not always-on-top) for better UX
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.aspectRatio = NSSize(width: 16, height: 9)
        window.minSize = NSSize(width: 320, height: 180)
        window.backgroundColor = .black

        // Set accessibility identifier for UI testing
        window.identifier = NSUserInterfaceItemIdentifier(AccessibilityID.VideoWindow.container)

        // Position at saved corner
        self.positionAtCorner(window: window, corner: self.currentCorner)

        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.isClosing = false

        // Observe window close (for red X button)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.windowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )

        // Update WebView display mode for video
        self.logger.info("Calling updateDisplayMode(.video)")
        SingletonPlayerWebView.shared.updateDisplayMode(.video)
    }

    /// Closes the video window programmatically (called when showVideo becomes false).
    func close() {
        self.logger.debug("VideoWindowController.close() called")

        // Prevent re-entrant calls
        guard !self.isClosing else {
            self.logger.debug("Already closing, skipping")
            return
        }

        guard let window = self.window else {
            self.logger.debug("No window to close")
            return
        }

        self.isClosing = true
        self.logger.info("Closing video window")

        // Remove observer before closing to prevent windowWillClose from firing
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)

        // Save corner position
        self.currentCorner = self.nearestCorner(for: window)
        self.saveCorner()

        // Clean up
        self.performCleanup()

        // Actually close the window
        window.close()
    }

    /// Called when window is closed via the red X button.
    @objc private func windowWillClose(_ notification: Notification) {
        self.logger.info("windowWillClose notification received")

        // Prevent re-entrant calls
        guard !self.isClosing else {
            self.logger.debug("Already closing, skipping windowWillClose")
            return
        }
        self.isClosing = true

        // Update corner based on final position
        if let window = notification.object as? NSWindow {
            self.currentCorner = self.nearestCorner(for: window)
            self.saveCorner()
        }

        // Clean up
        self.performCleanup()

        // Sync PlayerService state - this handles close via red button
        // This will trigger MainWindow.onChange which calls close(), but isClosing prevents re-entry
        if self.playerService?.showVideo == true {
            self.logger.debug("Syncing playerService.showVideo to false")
            self.playerService?.showVideo = false
        }
    }

    /// Shared cleanup logic for both close paths.
    private func performCleanup() {
        self.logger.debug("performCleanup called")

        // Clear grace period
        self.playerService?.videoWindowDidClose()

        // Return WebView to hidden mode (removes video container CSS)
        SingletonPlayerWebView.shared.updateDisplayMode(.hidden)

        // Clear references
        self.window = nil
        self.hostingView = nil

        // Reset close guard so future close operations can proceed
        self.isClosing = false
    }

    private func positionAtCorner(window: NSWindow, corner: Corner) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size
        let padding: CGFloat = 20

        let origin =
            switch corner {
            case .topLeft:
                NSPoint(
                    x: screenFrame.minX + padding,
                    y: screenFrame.maxY - windowSize.height - padding
                )
            case .topRight:
                NSPoint(
                    x: screenFrame.maxX - windowSize.width - padding,
                    y: screenFrame.maxY - windowSize.height - padding
                )
            case .bottomLeft:
                NSPoint(
                    x: screenFrame.minX + padding,
                    y: screenFrame.minY + padding
                )
            case .bottomRight:
                NSPoint(
                    x: screenFrame.maxX - windowSize.width - padding,
                    y: screenFrame.minY + padding
                )
            }

        window.setFrameOrigin(origin)
    }

    private func nearestCorner(for window: NSWindow) -> Corner {
        guard let screen = NSScreen.main else { return .bottomRight }
        let screenFrame = screen.visibleFrame
        let windowCenter = NSPoint(
            x: window.frame.midX,
            y: window.frame.midY
        )
        let screenCenter = NSPoint(
            x: screenFrame.midX,
            y: screenFrame.midY
        )

        let isLeft = windowCenter.x < screenCenter.x
        let isTop = windowCenter.y > screenCenter.y

        switch (isLeft, isTop) {
        case (true, true): return .topLeft
        case (false, true): return .topRight
        case (true, false): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }

    private func saveCorner() {
        UserDefaults.standard.set(self.currentCorner.rawValue, forKey: "videoWindowCorner")
    }

    private func loadCorner() {
        let raw = UserDefaults.standard.integer(forKey: "videoWindowCorner")
        self.currentCorner = Corner(rawValue: raw) ?? .bottomRight
    }
}
