import AppKit
import SwiftUI

// MARK: - VideoWindowController

/// Manages the floating video PiP window.
@MainActor
final class VideoWindowController {
    static let shared = VideoWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    private let logger = DiagnosticsLogger.player

    /// Reference to PlayerService to sync showVideo state
    private weak var playerService: PlayerService?

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
        // Write debug log to file
        Self.writeDebugLog("VideoWindowController.show() called")

        // Store reference to sync state on close
        self.playerService = playerService

        // Start grace period to prevent race condition when video element is moved
        playerService.videoWindowDidOpen()

        if let existingWindow = window {
            // Window exists - just bring it to front
            Self.writeDebugLog("Window already exists, bringing to front")
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        Self.writeDebugLog("Creating new video window")
        self.logger.info("Opening video window")

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
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.aspectRatio = NSSize(width: 16, height: 9)
        window.minSize = NSSize(width: 320, height: 180)
        window.backgroundColor = .black

        // Position at saved corner
        self.positionAtCorner(window: window, corner: self.currentCorner)

        window.makeKeyAndOrderFront(nil)
        self.window = window

        // Observe window close
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

    /// Closes the video window.
    func close() {
        Self.writeDebugLog("VideoWindowController.close() called")

        guard let window = self.window else {
            Self.writeDebugLog("No window to close")
            return
        }

        self.logger.info("Closing video window")

        // Remove observer before closing to prevent double-handling
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)

        // Clear grace period
        self.playerService?.videoWindowDidClose()

        window.close()
        self.window = nil
        self.hostingView = nil

        // Return WebView to hidden mode
        SingletonPlayerWebView.shared.updateDisplayMode(.hidden)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        Self.writeDebugLog("windowWillClose called")

        // Update corner based on final position
        if let window = notification.object as? NSWindow {
            self.currentCorner = self.nearestCorner(for: window)
            self.saveCorner()
        }

        // Clean up
        self.window = nil
        self.hostingView = nil

        // Return WebView to hidden mode
        SingletonPlayerWebView.shared.updateDisplayMode(.hidden)

        // Clear grace period
        self.playerService?.videoWindowDidClose()

        // Sync PlayerService state - this handles close via red button
        if self.playerService?.showVideo == true {
            Self.writeDebugLog("Syncing playerService.showVideo to false")
            self.playerService?.showVideo = false
        }
    }

    private func positionAtCorner(window: NSWindow, corner: Corner) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size
        let padding: CGFloat = 20

        var origin = switch corner {
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

    /// Write debug log to a file for debugging.
    private static func writeDebugLog(_ message: String) {
        let logFile = URL(fileURLWithPath: "/tmp/kaset_video_debug.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] [VideoWindowController] \(message)\n"
        if let data = logLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
        print("[Kaset Video Debug] \(message)")
    }
}
