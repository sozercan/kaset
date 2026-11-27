import CoreGraphics

enum PlayerBarLayout {
    private static let sidebarWidth: CGFloat = 220
    private static let contentHorizontalPadding: CGFloat = 32
    private static let compactBreakpointTolerance: CGFloat = 8

    static let compactDetailsBreakpoint: CGFloat = MainWindowLayout.minimumWidth
        - sidebarWidth
        - contentHorizontalPadding
        + compactBreakpointTolerance
}
