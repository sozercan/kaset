import AppKit
import SwiftUI

// MARK: - MusicIslandLayoutMetrics

struct MusicIslandLayoutMetrics: Equatable {
    let notchWidth: CGFloat
    let notchDepth: CGFloat
    let contentHeight: CGFloat
    let windowWidth: CGFloat
    let windowHeight: CGFloat

    static func metrics(for screen: NSScreen?) -> Self {
        let contentHeight: CGFloat = 54
        guard let screen,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea,
              !leftArea.isEmpty,
              !rightArea.isEmpty
        else {
            return Self(
                notchWidth: 0,
                notchDepth: 0,
                contentHeight: contentHeight,
                windowWidth: 340,
                windowHeight: contentHeight
            )
        }

        let frame = screen.frame
        let notchWidth = max(CGFloat(0), rightArea.minX - leftArea.maxX)
        guard notchWidth > 40 else {
            return Self(
                notchWidth: 0,
                notchDepth: 0,
                contentHeight: contentHeight,
                windowWidth: 340,
                windowHeight: contentHeight
            )
        }
        let notchDepth = max(screen.safeAreaInsets.top, max(frame.maxY - leftArea.minY, frame.maxY - rightArea.minY))

        let windowWidth = max(340, min(520, notchWidth + 240))
        let windowHeight = notchDepth + contentHeight

        return Self(
            notchWidth: notchWidth,
            notchDepth: notchDepth,
            contentHeight: contentHeight,
            windowWidth: windowWidth,
            windowHeight: windowHeight
        )
    }
}

// MARK: - MusicIslandWindowController

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
        if let window {
            window.orderFrontRegardless()
            self.positionAtTopCenter(window: window)
            return true
        }

        let metrics = MusicIslandLayoutMetrics.metrics(for: NSScreen.main)
        self.context = context
        let contentView = MusicIslandView(metrics: metrics, openMainWindow: context.openMainWindow)
            .environment(context.snapshots)

        let hostingView = NSHostingView(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: metrics.windowWidth, height: metrics.windowHeight),
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
