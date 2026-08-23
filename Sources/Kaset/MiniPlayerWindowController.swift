import AppKit
import SwiftUI

// MARK: - MiniPlayerWindowController

/// Manages the Apple Music-style floating mini player window.
@MainActor
final class MiniPlayerWindowController {
    static let shared = MiniPlayerWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    private weak var playerService: PlayerService?
    private var isClosing = false

    private let frameAutosaveKey = "KasetMiniPlayerWindow"

    private init() {}

    func show(
        playerService: PlayerService,
        client: any YTMusicClientProtocol,
        syncedLyricsService: SyncedLyricsService,
        authService: AuthService
    ) {
        self.playerService = playerService

        let contentView = MiniPlayerWindow(client: client)
            .environment(playerService)
            .environment(WebKitManager.shared)
            .environment(authService)
            .environment(FavoritesManager.shared)
            .environment(SongLikeStatusManager.shared)
            .environment(syncedLyricsService)

        if let existingWindow = self.window {
            self.isClosing = false
            self.hostingView?.rootView = AnyView(contentView)
            existingWindow.delegate = nil
            Self.hideStandardWindowButtons(existingWindow)
            self.applyWindowLevel(existingWindow)
            self.applySize(for: playerService.miniPlayerPanel, window: existingWindow)
            existingWindow.orderFront(nil)
            return
        }

        let hostingView = NSHostingView(rootView: AnyView(contentView))
        self.hostingView = hostingView

        let window = NSWindow(
            contentRect: Self.contentRect(for: playerService.miniPlayerPanel),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.title = "Mini Player"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.delegate = nil
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.identifier = NSUserInterfaceItemIdentifier(AccessibilityID.MiniPlayer.container)
        window.setFrameAutosaveName(self.frameAutosaveKey)
        Self.hideStandardWindowButtons(window)
        self.applyWindowLevel(window)

        if !window.setFrameUsingName(self.frameAutosaveKey) {
            self.positionAtDefaultLocation(window: window)
        }
        self.applySize(for: playerService.miniPlayerPanel, window: window)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.windowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )
        window.orderFront(nil)
        self.window = window
        self.isClosing = false
    }

    func close() {
        guard !self.isClosing else { return }
        guard let window = self.window else { return }

        self.isClosing = true
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        window.saveFrame(usingName: self.frameAutosaveKey)
        self.performCleanup()
        window.close()
    }

    func closeFromUserAction() {
        _ = self.playerService?.closeMiniPlayer() ?? false
        self.close()
    }

    func returnToMainWindowFromUserAction() {
        _ = self.playerService?.closeMiniPlayer(restoringMainWindow: true) ?? false
        self.close()
    }

    func miniaturizeFromUserAction() {
        self.window?.miniaturize(nil)
    }

    func syncWindowState() {
        guard let window, let playerService else { return }
        self.applyWindowLevel(window)
        self.applySize(for: playerService.miniPlayerPanel, window: window, animated: true)
    }

    func orderFrontIfVisible() {
        self.window?.orderFrontRegardless()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard !self.isClosing else { return }
        self.isClosing = true

        if let window = notification.object as? NSWindow {
            window.saveFrame(usingName: self.frameAutosaveKey)
        }

        _ = self.playerService?.closeMiniPlayer() ?? false
        self.performCleanup()
    }

    private func performCleanup() {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        }
        self.window = nil
        self.hostingView = nil
        self.playerService = nil
        self.isClosing = false
    }

    private func applyWindowLevel(_ window: NSWindow) {
        window.level = SettingsManager.shared.keepMiniPlayerOnTop ? .floating : .normal
    }

    private func applySize(for panel: PlayerService.MiniPlayerPanel, window: NSWindow, animated: Bool = false) {
        let size = Self.contentRect(for: panel).size
        let currentFrame = window.frame
        var nextFrame = currentFrame
        nextFrame.origin.y += currentFrame.height - size.height
        nextFrame.size = size
        let compactSize = Self.contentRect(for: .compact).size
        let lyricsSize = Self.contentRect(for: .lyrics).size
        window.minSize = compactSize
        window.maxSize = lyricsSize
        window.contentMinSize = compactSize
        window.contentMaxSize = lyricsSize
        window.setFrame(nextFrame, display: true, animate: animated)
    }

    private func positionAtDefaultLocation(window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size
        let padding: CGFloat = 32
        window.setFrameOrigin(
            NSPoint(
                x: screenFrame.maxX - windowSize.width - padding,
                y: screenFrame.maxY - windowSize.height - padding
            )
        )
    }

    private static func contentRect(for panel: PlayerService.MiniPlayerPanel) -> NSRect {
        switch panel {
        case .compact:
            NSRect(x: 0, y: 0, width: 320, height: 184)
        case .expanded:
            NSRect(x: 0, y: 0, width: 320, height: 320)
        case .lyrics:
            NSRect(x: 0, y: 0, width: 320, height: 500)
        }
    }

    private static func hideStandardWindowButtons(_ window: NSWindow) {
        [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ].forEach { buttonType in
            window.standardWindowButton(buttonType)?.isHidden = true
        }
    }
}
