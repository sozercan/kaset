import AppKit
import SwiftUI

// MARK: - MusicIslandWindowController

/// Manages the floating Music Island window.
@available(macOS 26.0, *)
@MainActor
final class MusicIslandWindowController {
    static let shared = MusicIslandWindowController()

    private var window: NSWindow?
    private var isVisible = false

    private init() {}

    /// Shows or updates the music island window.
    func show(
        playerService: PlayerService,
        lyricsService: SyncedLyricsService
    ) {
        if let existingWindow = self.window {
            if !self.isVisible {
                existingWindow.orderFront(nil)
                self.isVisible = true
            }
            return
        }

        let contentView = MusicIslandView()
            .environment(playerService)
            .environment(lyricsService)

        let hostingView = NSHostingView(rootView: AnyView(contentView))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .popUpMenu // Always on top of everything
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        // Position at top center
        self.positionAtTopCenter(window: window)

        // Show without stealing focus
        window.orderFrontRegardless()
        
        self.window = window
        self.isVisible = true
        
        // Observe screen changes to reposition
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Hides the music island window.
    func hide() {
        guard let window = self.window, self.isVisible else { return }
        window.orderOut(nil)
        self.isVisible = false
    }

    @objc private func screenParametersChanged() {
        guard let window = self.window, self.isVisible else { return }
        self.positionAtTopCenter(window: window)
    }

    private func positionAtTopCenter(window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size
        
        // 12px margin from the top menu bar
        let origin = NSPoint(
            x: screenFrame.midX - (windowSize.width / 2),
            y: screenFrame.maxY - windowSize.height - 12
        )

        window.setFrameOrigin(origin)
    }
}
