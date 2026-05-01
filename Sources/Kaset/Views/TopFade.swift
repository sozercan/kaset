import SwiftUI

// MARK: - TopFade

/// A lightweight top overlay that fades scrolling content beneath hidden toolbar backgrounds.
@available(macOS 26.0, *)
struct TopFade: View {
    let height: CGFloat

    var body: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor).opacity(0.98),
                Color(nsColor: .windowBackgroundColor).opacity(0.72),
                Color(nsColor: .windowBackgroundColor).opacity(0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: self.height)
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - TopFadeModifier

@available(macOS 26.0, *)
struct TopFadeModifier: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                TopFade(height: self.height)
            }
    }
}

@available(macOS 26.0, *)
extension View {
    /// Adds the same top fade treatment used by toolbar-backed pages when the toolbar background is hidden.
    /// - Parameter height: The height of the fade overlay.
    /// - Returns: A view with a non-interactive top fade overlay.
    func topFade(height: CGFloat = 96) -> some View {
        modifier(TopFadeModifier(height: height))
    }
}
