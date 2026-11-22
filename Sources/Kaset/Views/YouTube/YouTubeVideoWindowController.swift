import AppKit
import SwiftUI

@MainActor
enum YouTubeVideoWindowLevelPolicy {
    static let requiredCollectionBehavior: NSWindow.CollectionBehavior = [
        .managed,
        .participatesInCycle,
        .fullScreenPrimary,
    ]

    static func windowedLevel(isPinned: Bool) -> NSWindow.Level {
        isPinned ? .floating : .normal
    }

    static func canApplyLiveChange(isFullscreenOrTransitioning: Bool) -> Bool {
        !isFullscreenOrTransitioning
    }

    static func canToggleFloatOnTop(
        isFloating: Bool,
        isFullscreenOrTransitioning: Bool
    ) -> Bool {
        isFloating && !isFullscreenOrTransitioning
    }

    static func shouldShowChrome(
        isWindowHovered: Bool,
        isVolumeOverlayPresented: Bool
    ) -> Bool {
        isWindowHovered || isVolumeOverlayPresented
    }

    static func collectionBehavior(
        preserving current: NSWindow.CollectionBehavior
    ) -> NSWindow.CollectionBehavior {
        var behavior = current
        behavior.remove(.transient)
        behavior.remove(.stationary)
        behavior.remove(.ignoresCycle)
        behavior.formUnion(self.requiredCollectionBehavior)
        return behavior
    }

    static func configureCollectionBehavior(of window: NSWindow) {
        window.collectionBehavior = self.collectionBehavior(preserving: window.collectionBehavior)
    }

    static func applyWindowedLevel(isPinned: Bool, to window: NSWindow) {
        window.level = self.windowedLevel(isPinned: isPinned)
    }
}

enum YouTubeVideoWindowFullscreenPhase: Equatable {
    case windowed
    case entering
    case fullscreen
    case exiting

    var blocksWindowedControls: Bool {
        self != .windowed
    }
}

@MainActor
final class YouTubeVideoWindowController {
    static let shared = YouTubeVideoWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    private weak var youtubePlayerService: YouTubePlayerService?
    private var isClosing = false
    private let frameAutosaveKey = "KasetYouTubeVideoWindow"

    private static let minContentSize = NSSize(width: 512, height: 288)

    private var resizeGuard: YouTubeVideoWindowResizeGuard?

    private var fullscreenIntent = YouTubeVideoWindowFullscreenIntentState()

    private init() {}

    func show(youtubePlayerService: YouTubePlayerService, authService: AuthService) {
        self.youtubePlayerService = youtubePlayerService

        if let existingWindow = self.window {
            self.isClosing = false
            existingWindow.title = youtubePlayerService.currentVideo?.title ?? "YouTube"
            self.syncWindowState()
            existingWindow.orderFront(nil)
            return
        }

        let contentView = YouTubeVideoWindowContent()
            .environment(youtubePlayerService)
            .environment(authService)

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
        self.applyDesiredWindowedLevel(to: window)
        YouTubeVideoWindowLevelPolicy.configureCollectionBehavior(of: window)
        let resizeGuard = YouTubeVideoWindowResizeGuard(
            minContentSize: Self.minContentSize,
            onDidFailToEnterFullScreen: { [weak self] window in
                self?.handleFailedFullscreenEntry(window)
            }
        )
        self.resizeGuard = resizeGuard
        window.delegate = resizeGuard
        window.contentMinSize = Self.minContentSize
        window.backgroundColor = .black
        window.setFrameAutosaveName(self.frameAutosaveKey)
        window.identifier = NSUserInterfaceItemIdentifier(AccessibilityID.YouTubeContent.videoWindow)

        if !window.setFrameUsingName(self.frameAutosaveKey) {
            self.positionAtDefaultLocation(window: window)
        }
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
            selector: #selector(self.windowWillEnterFullScreen),
            name: NSWindow.willEnterFullScreenNotification,
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
            selector: #selector(self.windowWillExitFullScreen),
            name: NSWindow.willExitFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.windowDidExitFullScreen),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
    }

    func syncWindowState() {
        guard let window = self.window else { return }
        let isFullscreenOrTransitioning = self.youtubePlayerService?.windowFullscreenPhase.blocksWindowedControls == true
            || window.styleMask.contains(.fullScreen)
        guard YouTubeVideoWindowLevelPolicy.canApplyLiveChange(
            isFullscreenOrTransitioning: isFullscreenOrTransitioning
        ) else { return }

        self.applyDesiredWindowedLevel(to: window)
    }

    private func applyDesiredWindowedLevel(to window: NSWindow) {
        YouTubeVideoWindowLevelPolicy.applyWindowedLevel(
            isPinned: SettingsManager.shared.keepYouTubeVideoOnTop,
            to: window
        )
    }

    @objc private func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        self.youtubePlayerService?.windowFullscreenPhase = .entering
        self.applyFrameAutosaveTransition(.willEnterFullScreen, to: window)
    }

    @objc private func windowDidEnterFullScreen(_: Notification) {
        self.youtubePlayerService?.windowFullscreenPhase = .fullscreen
    }

    @objc private func windowWillExitFullScreen(_: Notification) {
        self.youtubePlayerService?.windowFullscreenPhase = .exiting
    }

    @objc private func windowDidExitFullScreen(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            self.applyFrameAutosaveTransition(.didExitFullScreen, to: window)
            self.applyDesiredWindowedLevel(to: window)
        }
        self.youtubePlayerService?.windowFullscreenPhase = .windowed
        if self.fullscreenIntent.consumeReturnInlineOnExit() {
            self.youtubePlayerService?.requestPopIn()
        }
    }

    private func handleFailedFullscreenEntry(_ window: NSWindow) {
        self.applyFrameAutosaveTransition(.didFailToEnterFullScreen, to: window)
        self.fullscreenIntent.cancelReturnInlineOnExit()
        self.applyDesiredWindowedLevel(to: window)
        self.youtubePlayerService?.windowFullscreenPhase = .windowed
    }

    private func applyFrameAutosaveTransition(
        _ transition: YouTubeVideoWindowFrameAutosaveState.Transition,
        to window: NSWindow
    ) {
        var state = YouTubeVideoWindowFrameAutosaveState(
            restorableName: self.frameAutosaveKey,
            currentName: window.frameAutosaveName
        )
        state.handle(transition)
        window.setFrameAutosaveName(state.currentName)
    }

    func toggleFullscreen(returnInlineOnExit: Bool = false) {
        guard let window = self.window else { return }
        if window.styleMask.contains(.fullScreen) {
            self.youtubePlayerService?.windowFullscreenPhase = .exiting
        } else {
            self.youtubePlayerService?.windowFullscreenPhase = .entering
            if returnInlineOnExit {
                self.fullscreenIntent.requestReturnInlineOnExit()
            }
        }
        window.toggleFullScreen(nil)
    }

    func setWindowChromeVisible(_ visible: Bool) {
        guard let window = self.window else { return }
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(buttonType)?.animator().alphaValue = visible ? 1 : 0
        }
    }

    func close() {
        guard !self.isClosing else { return }
        guard let window = self.window else { return }

        self.isClosing = true
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        self.saveFrameIfRestorable(window)
        self.performCleanup()
        window.close()
    }

    private func saveFrameIfRestorable(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        window.saveFrame(usingName: self.frameAutosaveKey)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard !self.isClosing else { return }
        self.isClosing = true

        if let window = notification.object as? NSWindow {
            self.saveFrameIfRestorable(window)
        }

        let service = self.youtubePlayerService
        self.performCleanup()

        if service?.surfaceLocation == .floating {
            service?.stop()
        }
    }

    private func performCleanup() {
        self.youtubePlayerService?.windowFullscreenPhase = .windowed
        self.fullscreenIntent.cancelReturnInlineOnExit()
        if let window = self.window {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willEnterFullScreenNotification,
                object: window
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didEnterFullScreenNotification,
                object: window
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willExitFullScreenNotification,
                object: window
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didExitFullScreenNotification,
                object: window
            )
        }
        self.resizeGuard?.invalidate()
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

struct YouTubeVideoWindowFullscreenIntentState: Equatable {
    private(set) var returnsInlineOnExit = false

    mutating func requestReturnInlineOnExit() {
        self.returnsInlineOnExit = true
    }

    mutating func cancelReturnInlineOnExit() {
        self.returnsInlineOnExit = false
    }

    mutating func consumeReturnInlineOnExit() -> Bool {
        let shouldReturn = self.returnsInlineOnExit
        self.returnsInlineOnExit = false
        return shouldReturn
    }
}

struct YouTubeVideoWindowFrameAutosaveState: Equatable {
    enum Transition {
        case willEnterFullScreen
        case didFailToEnterFullScreen
        case didExitFullScreen
    }

    let restorableName: String
    private(set) var currentName: String

    init(restorableName: String, currentName: String? = nil) {
        self.restorableName = restorableName
        self.currentName = currentName ?? restorableName
    }

    mutating func handle(_ transition: Transition) {
        switch transition {
        case .willEnterFullScreen:
            self.currentName = ""
        case .didFailToEnterFullScreen, .didExitFullScreen:
            self.currentName = self.restorableName
        }
    }
}

@MainActor
final class YouTubeVideoWindowResizeGuard: NSObject, NSWindowDelegate {
    private let minContentSize: NSSize
    private var onDidFailToEnterFullScreen: ((NSWindow) -> Void)?

    init(
        minContentSize: NSSize,
        onDidFailToEnterFullScreen: ((NSWindow) -> Void)? = nil
    ) {
        self.minContentSize = minContentSize
        self.onDidFailToEnterFullScreen = onDidFailToEnterFullScreen
        super.init()
    }

    func invalidate() {
        self.onDidFailToEnterFullScreen = nil
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        self.onDidFailToEnterFullScreen?(window)
    }

    static func normalizedContentSize(
        for proposed: NSSize,
        minContentSize: NSSize,
        current: NSSize? = nil
    ) -> NSSize {
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
        guard !sender.styleMask.contains(.fullScreen) else { return frameSize }
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

private struct YouTubeVideoWindowContent: View {
    @Environment(YouTubePlayerService.self) private var youtubePlayer

    @State private var settings = SettingsManager.shared
    @State private var isHovering = false
    @State private var isVolumeOverlayPresented = false

    private static let dragStripHeight: CGFloat = 36

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .bottom) {
                YouTubeWatchSurfaceView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if self.showsWindowChrome {
                    YouTubePlayerBar(
                        isDetachedWindow: true,
                        onVolumeOverlayChange: { isPresented in
                            self.isVolumeOverlayPresented = isPresented
                        }
                    )
                    .transition(.opacity)
                }
            }

            WindowDragHandle()
                .frame(maxWidth: .infinity)
                .frame(height: Self.dragStripHeight)
                .overlay(alignment: .top) {
                    if self.showsWindowChrome {
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
        .environment(\.usesLegacyMacOS15UI, self.settings.useLegacyMacOS15UI)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                self.isHovering = hovering
            }
            YouTubeVideoWindowController.shared.setWindowChromeVisible(
                hovering || self.isVolumeOverlayPresented
            )
        }
        .onChange(of: self.isVolumeOverlayPresented) { _, isPresented in
            YouTubeVideoWindowController.shared.setWindowChromeVisible(
                self.isHovering || isPresented
            )
        }
    }

    private var showsWindowChrome: Bool {
        YouTubeVideoWindowLevelPolicy.shouldShowChrome(
            isWindowHovered: self.isHovering,
            isVolumeOverlayPresented: self.isVolumeOverlayPresented
        )
    }
}
