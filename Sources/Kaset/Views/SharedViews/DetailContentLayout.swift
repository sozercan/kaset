import SwiftUI

// MARK: - DetailContentLayout

/// Shared layout constants for detail-column content that slides under the
/// floating Liquid Glass sidebar on macOS 26.
///
/// On macOS 26 the `NavigationSplitView` sidebar renders as a floating,
/// translucent Liquid Glass panel and the detail column extends full-width
/// beneath it. To get the Apple Music "content slides under the sidebar" look,
/// detail scroll views must reach the column's leading/trailing edges (so their
/// content can scroll underneath the glass) while keeping a resting inset so
/// text and controls stay clear of the sidebar when not scrolling.
///
/// Apply ``horizontalInset`` as that resting inset:
/// - On scroll views, via `.contentMargins(.horizontal:for: .scrollContent)`,
///   which keeps the scroll view edge-to-edge but insets the *content*.
/// - On non-scrolling headers, via `.padding(.horizontal:)`.
///
/// Both `.contentMargins` and `.padding` are available on macOS 14+, so the
/// resting layout is identical on the legacy macOS 15 path (where there is no
/// floating sidebar to slide under).
enum DetailContentLayout {
    /// Horizontal resting inset (points) for detail content.
    ///
    /// Matches the previous fixed `.padding(.horizontal, 24)` so the resting
    /// layout is visually unchanged; only the scroll-under behavior is new.
    static let horizontalInset: CGFloat = 24
}
