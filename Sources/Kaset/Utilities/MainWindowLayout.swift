import AppKit

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

    static var minimumContentSize: NSSize {
        NSSize(width: minimumWidth, height: minimumHeight)
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
    @MainActor
    static func configure(_ window: NSWindow) {
        guard self.isPrimaryWindow(window) else { return }

        if window.frameAutosaveName.isEmpty {
            window.setFrameAutosaveName(self.autosaveName)
        }

        window.contentMinSize = self.minimumContentSize
        self.expandIfNeeded(window)
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
