import CoreGraphics

// MARK: - PlayerBarLayout

/// Shared sizing constants for the audio and video player bars.
enum PlayerBarLayout {
    private static let sidebarWidth: CGFloat = 220
    private static let contentHorizontalPadding: CGFloat = 32
    private static let compactBreakpointTolerance: CGFloat = 8

    /// Switches to compact media details when the content area approaches the
    /// minimum main-window width after removing the sidebar, app chrome padding,
    /// and a small tolerance for live-resize rounding.
    static let compactDetailsBreakpoint: CGFloat = MainWindowLayout.minimumWidth
        - sidebarWidth
        - contentHorizontalPadding
        + compactBreakpointTolerance
}
