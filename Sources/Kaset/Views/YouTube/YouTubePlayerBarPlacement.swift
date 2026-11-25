import AppKit
import SwiftUI

enum YouTubeInlineControlsVisibility {
    static let idleDelay: Duration = .seconds(3)

    static let controlsRegionHeight: CGFloat = 60

    static func shouldShow(
        isPlaying: Bool,
        isRecentlyActive: Bool,
        isPointerOverControls: Bool,
        isControlPopupOpen: Bool,
        isAssistiveNavigationActive: Bool
    ) -> Bool {
        !isPlaying
            || isRecentlyActive
            || isPointerOverControls
            || isControlPopupOpen
            || isAssistiveNavigationActive
    }

    static func isControlsRegionVisible(
        videoSize: CGSize,
        visibleBounds: CGRect?,
        bottomInset: CGFloat = 0
    ) -> Bool {
        guard let visibleBounds else { return true }
        return visibleBounds.minY <= videoSize.height - self.controlsRegionHeight + 1
            && visibleBounds.maxY + bottomInset >= videoSize.height - 1
    }
}

extension View {
    func youtubePlayerBarInset(isHidden: Bool = false) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if !isHidden {
                YouTubePlayerBar(isDetachedWindow: false)
            }
        }
    }

    func youtubePagePlayerBarInset(keepsBar: Bool = false) -> some View {
        self.modifier(YouTubePagePlayerBarInsetModifier(keepsBar: keepsBar))
    }
}

private struct YouTubePagePlayerBarInsetModifier: ViewModifier {
    let keepsBar: Bool

    @State private var settings = SettingsManager.shared

    func body(content: Content) -> some View {
        content.youtubePlayerBarInset(
            isHidden: !self.keepsBar && self.settings.showYouTubeControlsOnVideo
        )
    }
}

extension View {
    func youtubeInlineVideoControls(isEnabled: Bool) -> some View {
        self.modifier(YouTubeInlineVideoControlsModifier(isEnabled: isEnabled))
    }
}

private struct YouTubeInlineVideoControlsModifier: ViewModifier {
    private static let tabKeyCode: UInt16 = 48

    let isEnabled: Bool

    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled

    @State private var activity = UserActivity()
    @State private var isRecentlyActive = false
    @State private var isPointerOverControls = false
    @State private var isVolumeOverlayPresented = false
    @State private var isMenuOpen = false
    @State private var isKeyboardNavigating = false

    func body(content: Content) -> some View {
        content
            .background {
                if self.isEnabled {
                    YouTubeKeyActivityMonitor { event in
                        self.handleKeyDown(event)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                ZStack {
                    if self.isEnabled, self.showsControls {
                        YouTubePlayerBar(
                            isDetachedWindow: false,
                            onVolumeOverlayChange: { isPresented in
                                self.isVolumeOverlayPresented = isPresented
                            }
                        )
                        .onHover { hovering in
                            self.isPointerOverControls = hovering
                        }
                        .onDisappear {
                            self.isPointerOverControls = false
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: self.showsControls)
            }
            .onContinuousHover { phase in
                guard self.isEnabled else { return }
                switch phase {
                case let .active(location):
                    self.activity.isPointerInside = true
                    guard location != self.activity.lastPointerLocation else { return }
                    self.activity.lastPointerLocation = location
                    self.isKeyboardNavigating = false
                    self.registerActivity()
                case .ended:
                    self.activity.isPointerInside = false
                    self.activity.lastPointerLocation = nil
                    self.isRecentlyActive = false
                }
            }
            .task(id: self.isEnabled && self.isRecentlyActive) {
                await self.hideWhenIdle()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                self.isMenuOpen = self.isPointerOverControls
            }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
                self.isMenuOpen = false
            }
            .onChange(of: self.isMenuOpen) { _, isOpen in
                if !isOpen, self.activity.isPointerInside {
                    self.registerActivity()
                }
            }
            .onChange(of: self.isVolumeOverlayPresented) { _, isPresented in
                if !isPresented, self.activity.isPointerInside {
                    self.registerActivity()
                }
            }
            .onChange(of: self.showsControls) { _, shows in
                if !shows, self.isEnabled, self.activity.isPointerInside, NSApp.isActive {
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
            .onChange(of: self.isEnabled) { _, isEnabled in
                if !isEnabled {
                    self.resetInteractionState()
                }
            }
    }

    private var showsControls: Bool {
        YouTubeInlineControlsVisibility.shouldShow(
            isPlaying: self.youtubePlayer.isPlaying,
            isRecentlyActive: self.isRecentlyActive,
            isPointerOverControls: self.isPointerOverControls,
            isControlPopupOpen: self.isVolumeOverlayPresented || self.isMenuOpen,
            isAssistiveNavigationActive: self.isVoiceOverEnabled || self.isKeyboardNavigating
        )
    }

    private func handleKeyDown(_ event: NSEvent) {
        if event.keyCode == Self.tabKeyCode, NSApp.isFullKeyboardAccessEnabled {
            self.isKeyboardNavigating = true
        }
        self.registerActivity()
    }

    private func resetInteractionState() {
        self.activity.isPointerInside = false
        self.activity.lastPointerLocation = nil
        self.isRecentlyActive = false
        self.isPointerOverControls = false
        self.isVolumeOverlayPresented = false
        self.isMenuOpen = false
        self.isKeyboardNavigating = false
    }

    private func registerActivity() {
        self.activity.lastActivity = .now
        if !self.isRecentlyActive {
            self.isRecentlyActive = true
        }
    }

    private func hideWhenIdle() async {
        guard self.isEnabled, self.isRecentlyActive else { return }
        while true {
            let deadline = self.activity.lastActivity + YouTubeInlineControlsVisibility.idleDelay
            guard await (try? Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
            if ContinuousClock.now >= self.activity.lastActivity + YouTubeInlineControlsVisibility.idleDelay {
                break
            }
        }
        self.isRecentlyActive = false
    }
}

@MainActor
private final class UserActivity {
    var lastActivity = ContinuousClock.now
    var lastPointerLocation: CGPoint?
    var isPointerInside = false
}

private struct YouTubeKeyActivityMonitor: NSViewRepresentable {
    let onKeyDown: @MainActor (NSEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onKeyDown: self.onKeyDown)
    }

    func makeNSView(context: Context) -> YouTubeKeyActivityMonitorView {
        let view = YouTubeKeyActivityMonitorView(frame: .zero)
        view.isHidden = true
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.window = window
        }
        context.coordinator.window = view.window
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: YouTubeKeyActivityMonitorView, context: Context) {
        context.coordinator.onKeyDown = self.onKeyDown
        context.coordinator.window = view.window
    }

    static func dismantleNSView(_ view: YouTubeKeyActivityMonitorView, coordinator: Coordinator) {
        view.windowDidChange = nil
        coordinator.window = nil
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        var onKeyDown: @MainActor (NSEvent) -> Void
        weak var window: NSWindow?
        private var monitor: Any?

        init(onKeyDown: @escaping @MainActor (NSEvent) -> Void) {
            self.onKeyDown = onKeyDown
        }

        func install() {
            guard self.monitor == nil else { return }
            self.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let window = self.window,
                      event.window === window,
                      !(window.firstResponder is NSText)
                else {
                    return event
                }
                self.onKeyDown(event)
                return event
            }
        }

        func uninstall() {
            guard let monitor = self.monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

@MainActor
private final class YouTubeKeyActivityMonitorView: NSView {
    var windowDidChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.windowDidChange?(self.window)
    }
}
