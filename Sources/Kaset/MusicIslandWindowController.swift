import AppKit
import SwiftUI

@available(macOS 26.0, *)
@MainActor
final class MusicIslandWindowController: NowPlayingSurfaceAdapter {
    static let shared = MusicIslandWindowController()

    let descriptor = NowPlayingSurfaceDescriptor.musicIsland

    private var window: NSWindow?
    private var context: NowPlayingSurfaceContext?

    var isRunning: Bool {
        self.window != nil
    }

    private init() {}

    func start(context: NowPlayingSurfaceContext) async -> Bool {
        self.context = context
        if let window {
            window.orderFrontRegardless()
            self.positionAtTopCenter(window: window)
            return true
        }

        let contentView = MusicIslandView(openMainWindow: context.openMainWindow)
            .environment(context.snapshots)

        let hostingView = NSHostingView(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 498, height: 116),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.positionAtTopCenter(window: window)
        window.orderFrontRegardless()

        self.window = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        return true
    }

    func stop() async {
        self.window?.orderOut(nil)
        self.context = nil
    }

    @objc private func screenParametersChanged() {
        guard let window else { return }
        self.positionAtTopCenter(window: window)
    }

    private func positionAtTopCenter(window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let windowSize = window.frame.size
        let origin = NSPoint(
            x: screenFrame.midX - windowSize.width / 2,
            y: screenFrame.maxY - windowSize.height
        )

        window.setFrameOrigin(origin)
    }
}
