import AppKit
import SwiftUI

@MainActor
final class VideoWindowController {
    static let shared = VideoWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?

    private weak var playerService: PlayerService?

    private var isClosing = false

    private let frameAutosaveKey = "KasetVideoWindow"

    private init() {}

    func show(
        playerService: PlayerService,
        webKitManager: WebKitManager,
        authService: AuthService
    ) {
        self.playerService = playerService

        playerService.videoWindowDidOpen()

        if let existingWindow = self.window {
            self.isClosing = false
            existingWindow.orderFront(nil)
            SingletonPlayerWebView.shared.updateDisplayMode(.video)
            return
        }

        let contentView = VideoPlayerWindow()
            .environment(playerService)
            .environment(webKitManager)
            .environment(authService)

        let hostingView = NSHostingView(rootView: AnyView(contentView))
        self.hostingView = hostingView

        let defaultRect = NSRect(x: 0, y: 0, width: 480, height: 270)
        let window = NSWindow(
            contentRect: defaultRect,
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
        window.minSize = NSSize(width: 160, height: 90)
        window.backgroundColor = .black

        window.setFrameAutosaveName(self.frameAutosaveKey)

        window.identifier = NSUserInterfaceItemIdentifier(AccessibilityID.VideoWindow.container)

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

        SingletonPlayerWebView.shared.updateDisplayMode(.video)
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

    @objc private func windowWillClose(_ notification: Notification) {
        guard !self.isClosing else { return }
        self.isClosing = true

        if let window = notification.object as? NSWindow {
            window.saveFrame(usingName: self.frameAutosaveKey)
        }

        self.performCleanup()

        if self.playerService?.showVideo == true {
            self.playerService?.showVideo = false
        }
    }

    private func performCleanup() {
        self.playerService?.videoWindowDidClose()

        SingletonPlayerWebView.shared.updateDisplayMode(.hidden)

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
