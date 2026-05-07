import AppKit
import SwiftUI

// MARK: - MiniPlayerWindowController

/// Manages the Apple Music-style floating mini player window.
@available(macOS 26.0, *)
@MainActor
final class MiniPlayerWindowController {
    static let shared = MiniPlayerWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    private weak var playerService: PlayerService?
    private var restoreMainWindow: (() -> Void)?
    private var isClosing = false
    private var isApplyingProgrammaticSize = false

    private let frameAutosaveKey = "KasetMiniPlayerWindow"

    private init() {}

    func show(
        playerService: PlayerService,
        client: any YTMusicClientProtocol,
        syncedLyricsService: SyncedLyricsService,
        restoreMainWindow: @escaping () -> Void
    ) {
        self.playerService = playerService
        self.restoreMainWindow = restoreMainWindow

        let contentView = MiniPlayerWindow(client: client)
            .environment(playerService)
            .environment(WebKitManager.shared)
            .environment(FavoritesManager.shared)
            .environment(SongLikeStatusManager.shared)
            .environment(syncedLyricsService)

        if let existingWindow = self.window {
            self.isClosing = false
            self.hostingView?.rootView = AnyView(contentView)
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
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.title = "Mini Player"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.windowDidEndLiveResize),
            name: NSWindow.didEndLiveResizeNotification,
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
        NotificationCenter.default.removeObserver(self, name: NSWindow.didEndLiveResizeNotification, object: window)
        window.saveFrame(usingName: self.frameAutosaveKey)
        self.performCleanup()
        window.close()
    }

    func closeFromUserAction() {
        _ = self.playerService?.closeMiniPlayer() ?? false
        self.close()
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

    @objc private func windowDidEndLiveResize(_ notification: Notification) {
        guard !self.isApplyingProgrammaticSize else { return }
        guard let window = notification.object as? NSWindow else { return }
        let panel = Self.nearestPanel(for: window.frame.size)
        self.playerService?.miniPlayerPanel = panel
        self.applySize(for: panel, window: window, animated: true)
    }

    private func performCleanup() {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didEndLiveResizeNotification, object: window)
        }
        self.window = nil
        self.hostingView = nil
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
        window.minSize = Self.contentRect(for: .compact).size
        window.maxSize = Self.contentRect(for: .lyrics).size
        self.isApplyingProgrammaticSize = true
        window.setFrame(nextFrame, display: true, animate: animated)
        self.isApplyingProgrammaticSize = false
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
            NSRect(x: 0, y: 0, width: 320, height: 146)
        case .expanded:
            NSRect(x: 0, y: 0, width: 320, height: 320)
        case .lyrics:
            NSRect(x: 0, y: 0, width: 320, height: 500)
        }
    }

    private static func nearestPanel(for size: CGSize) -> PlayerService.MiniPlayerPanel {
        if size.height <= 260 || size.height < size.width * 0.82 {
            return .compact
        }

        if size.height >= 410 {
            return .lyrics
        }

        return .expanded
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
