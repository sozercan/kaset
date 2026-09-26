import AppKit
import SwiftUI

// MARK: - YouTubeInlineControlsVisibility

/// Show/hide policy for the player controls overlaid on the docked watch-page
/// video (Settings → YouTube → Show Controls on Video). Without that setting
/// the bar sits in the bottom inset below.
enum YouTubeInlineControlsVisibility {
    /// How long the pointer can rest over a playing video (with no key
    /// presses) before the controls fade out.
    static let idleDelay: Duration = .seconds(3)

    /// Height of the strip at the bottom of the video the bar occupies (the
    /// 52pt capsule plus its 8pt bottom padding).
    static let controlsRegionHeight: CGFloat = 60

    /// Like a regular video player: visible while paused, for `idleDelay`
    /// after the pointer moves over the video or a key is pressed, while the
    /// pointer rests on the controls, and while one of the bar's menus or its
    /// volume capsule is open. Assistive navigation (VoiceOver, or Tabbing with
    /// Keyboard Navigation) keeps them visible: hidden controls can't be
    /// reached by focus.
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

    /// Whether the bottom strip of a video the controls would occupy lies fully
    /// inside the scroll view. A tall 16:9 video in a wide window can be mostly
    /// visible with that strip below the fold, so the whole-video fraction is
    /// not enough to hand the controls over.
    ///
    /// - Parameter visibleBounds: the scroll view's bounds in the video's local
    ///   coordinates; `nil` outside a scroll view.
    static func isControlsRegionVisible(videoSize: CGSize, visibleBounds: CGRect?) -> Bool {
        guard let visibleBounds else { return true }
        // A point of slack absorbs fractional layout rounding at either edge.
        return visibleBounds.minY <= videoSize.height - self.controlsRegionHeight + 1
            && visibleBounds.maxY >= videoSize.height - 1
    }
}

// MARK: - Per-View Inset

extension View {
    /// Attaches the YouTube player bar to the bottom of a navigable view.
    ///
    /// Applied to EVERY YouTube view (roots and pushed destinations) —
    /// views pushed onto a `NavigationStack` do not inherit a parent's
    /// `safeAreaInset`, the same rule the music side follows with
    /// `PlayerBar` (see docs/architecture.md).
    ///
    /// - Parameter isHidden: lets the watch page drop the bar while its docked
    ///   video carries the controls instead.
    func youtubePlayerBarInset(isHidden: Bool = false) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if !isHidden {
                YouTubePlayerBar(isDetachedWindow: false)
            }
        }
    }

    /// Attaches the bar to a YouTube page without a watch video of its own
    /// (feeds, search, channels, playlists). With Show Controls on Video on,
    /// these pages drop it: a video started from them plays in the pop-out
    /// window, which carries its own controls.
    ///
    /// - Parameter keepsBar: Shorts keeps the bar regardless, since its
    ///   vertical pager has no controls of its own.
    func youtubePagePlayerBarInset(keepsBar: Bool = false) -> some View {
        self.modifier(YouTubePagePlayerBarInsetModifier(keepsBar: keepsBar))
    }
}

// MARK: - YouTubePagePlayerBarInsetModifier

private struct YouTubePagePlayerBarInsetModifier: ViewModifier {
    let keepsBar: Bool

    @State private var settings = SettingsManager.shared

    func body(content: Content) -> some View {
        content.youtubePlayerBarInset(
            isHidden: !self.keepsBar && self.settings.showYouTubeControlsOnVideo
        )
    }
}

// MARK: - Inline Video Controls

extension View {
    /// Overlays the YouTube player bar on the docked watch-page video. The bar
    /// appears when the pointer moves over the video or a key is pressed, and
    /// fades out (hiding the cursor) after a few idle seconds of playback.
    func youtubeInlineVideoControls(isEnabled: Bool) -> some View {
        self.modifier(YouTubeInlineVideoControlsModifier(isEnabled: isEnabled))
    }
}

// MARK: - YouTubeInlineVideoControlsModifier

private struct YouTubeInlineVideoControlsModifier: ViewModifier {
    private static let tabKeyCode: UInt16 = 48

    let isEnabled: Bool

    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled

    /// Updated on every pointer move without re-rendering; only the idle task
    /// and hover handling read it.
    @State private var activity = UserActivity()
    @State private var isRecentlyActive = false
    @State private var isPointerOverControls = false
    @State private var isVolumeOverlayPresented = false
    @State private var isMenuOpen = false
    /// Set by Tab with Keyboard Navigation on, when focus may be in the bar;
    /// cleared once the pointer moves over the video again.
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
                    // Hover can re-report an unchanged location (layout under a
                    // resting pointer); only real movement counts as activity.
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
            // The captions and quality menus track in their own run loop, so the
            // pointer stops reporting movement while one is open. Only a menu
            // opened from the bar counts, not the menu bar or a context menu.
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                self.isMenuOpen = self.isPointerOverControls
            }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
                self.isMenuOpen = false
            }
            // Give the pointer a fresh idle window after a menu or the volume
            // capsule closes, rather than hiding the bar the instant it does.
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
            // Hide the cursor with the controls, whether they fade from idleness
            // or because playback resumed while the pointer was already resting.
            .onChange(of: self.showsControls) { _, shows in
                if !shows, self.isEnabled, self.activity.isPointerInside, NSApp.isActive {
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
            // Removing the bar tears down its menus and volume capsule without
            // reporting their dismissal, so reset the interaction state here.
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

    /// Clears recent activity once the pointer and keyboard have rested for
    /// `idleDelay`. Activity only advances the timestamp, so this loop re-arms
    /// itself instead of restarting a task on every event.
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

// MARK: - UserActivity

@MainActor
private final class UserActivity {
    var lastActivity = ContinuousClock.now
    var lastPointerLocation: CGPoint?
    var isPointerInside = false
}

// MARK: - YouTubeKeyActivityMonitor

/// Reports key presses in its window, except while text input has focus
/// (the comment composer, search), so the keyboard can reveal the inline
/// controls the way pointer movement does. Events pass through untouched.
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

// MARK: - YouTubeKeyActivityMonitorView

@MainActor
private final class YouTubeKeyActivityMonitorView: NSView {
    var windowDidChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.windowDidChange?(self.window)
    }
}
