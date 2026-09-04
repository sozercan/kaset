import AppKit
import SwiftUI

// MARK: - MainWindowLayout

/// Shared sizing contract for Kaset's primary app window.
///
/// SwiftUI's `.frame(minWidth:minHeight:)` documents the layout floor for the
/// view hierarchy, while this helper applies the same floor to the underlying
/// `NSWindow` so live resizing and restored autosaved frames cannot shrink the
/// window below the point where the sidebar/player controls remain usable.
enum MainWindowLayout {
    static let autosaveName = "KasetMainWindow"
    static let windowTitle = "Kaset"
    static let minimumWidth: CGFloat = 980
    static let minimumHeight: CGFloat = 600
    static let defaultWidth: CGFloat = 1100
    static let defaultHeight: CGFloat = 760
    /// Shared top inset for the Music command bar and YouTube Ask panel.
    static let aiTaskSurfaceTopPadding: CGFloat = 72

    static var minimumContentSize: NSSize {
        NSSize(width: self.minimumWidth, height: self.minimumHeight)
    }

    /// Returns true for windows that are known to be the primary app window.
    static func isPrimaryWindowIdentity(title: String, frameAutosaveName: String) -> Bool {
        frameAutosaveName == self.autosaveName || title == self.windowTitle
    }

    @MainActor
    static func isPrimaryWindow(_ window: NSWindow) -> Bool {
        self.isPrimaryWindowIdentity(title: window.title, frameAutosaveName: window.frameAutosaveName)
    }

    /// Applies the primary-window sizing contract to an AppKit window.
    /// Sets up transparent titlebar with fullSizeContentView for windowed mode.
    /// In fullscreen, macOS handles the titlebar natively — we don't override.
    @MainActor
    static func configure(_ window: NSWindow) {
        guard self.isPrimaryWindow(window) else { return }

        self.configureKnownPrimaryWindow(window)
    }

    /// Applies the primary-window contract when the caller already owns the
    /// main SwiftUI scene and does not need title-based discovery.
    @MainActor
    static func configureKnownPrimaryWindow(_ window: NSWindow) {
        if window.frameAutosaveName.isEmpty {
            window.setFrameAutosaveName(self.autosaveName)
        }

        window.contentMinSize = self.minimumContentSize
        self.expandIfNeeded(window)

        // Only apply custom titlebar settings in windowed mode.
        // In fullscreen, macOS manages its own auto-hiding titlebar.
        guard !window.styleMask.contains(.fullScreen) else { return }

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
    }

    /// Re-applies windowed-mode titlebar settings after exiting fullscreen.
    /// macOS may reset window properties during the fullscreen transition.
    @MainActor
    static func restoreWindowedAppearance(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
    }

    /// Pure clamp used by both AppKit configuration and tests.
    static func clampedContentSize(_ contentSize: NSSize) -> NSSize {
        NSSize(
            width: max(contentSize.width, self.minimumWidth),
            height: max(contentSize.height, self.minimumHeight)
        )
    }

    @MainActor
    private static func expandIfNeeded(_ window: NSWindow) {
        let currentFrame = window.frame
        let currentContentSize = window.contentRect(forFrameRect: currentFrame).size
        let clampedContentSize = Self.clampedContentSize(currentContentSize)

        guard clampedContentSize.width > currentContentSize.width
            || clampedContentSize.height > currentContentSize.height
        else { return }

        let clampedFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: clampedContentSize)
        ).size
        var clampedFrame = currentFrame
        clampedFrame.size = clampedFrameSize
        // Keep the titlebar/top edge anchored when expanding a stale restored
        // frame, so the window does not jump downward on launch/reopen.
        clampedFrame.origin.y = currentFrame.maxY - clampedFrameSize.height

        let constrainedFrame = window.constrainFrameRect(clampedFrame, to: window.screen)
        window.setFrame(constrainedFrame, display: true)
    }
}

// MARK: - WindowDragHandle

/// Native view representable that supports dragging the window and handling double-clicks.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context _: Context) -> WindowDragNSView {
        WindowDragNSView()
    }

    func updateNSView(_: WindowDragNSView, context _: Context) {}
}

// MARK: - WindowDragNSView

/// Backing NSView for WindowDragHandle.
final class WindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize":
                self.window?.miniaturize(nil)
            case "None":
                break
            default: // "Maximize" (zoom) is the macOS default.
                self.window?.performZoom(nil)
            }
        } else {
            self.window?.performDrag(with: event)
        }
    }
}
