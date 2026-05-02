import SwiftUI

// MARK: - TopFade

/// Retained for source compatibility with detail pages that previously applied a top overlay.
@available(macOS 26.0, *)
struct TopFade: View {
    let height: CGFloat

    var body: some View {
        EmptyView()
    }
}

// MARK: - TopFadeModifier

@available(macOS 26.0, *)
struct TopFadeModifier: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        content
    }
}

@available(macOS 26.0, *)
extension View {
    /// No-op compatibility hook for pages that previously applied a top fade.
    /// - Parameter height: The height of the fade overlay.
    /// - Returns: The view unchanged.
    func topFade(height: CGFloat = 96) -> some View {
        modifier(TopFadeModifier(height: height))
    }
}
