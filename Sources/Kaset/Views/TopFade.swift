import SwiftUI

// MARK: - TopFade

/// A lightweight top overlay that fades scrolling content beneath hidden toolbar backgrounds.
@available(macOS 26.0, *)
struct TopFade: View {
    let height: CGFloat

    var body: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.42),
                Color.black.opacity(0.26),
                Color.black.opacity(0.08),
                Color.clear,
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
    }
}

@available(macOS 26.0, *)
extension View {
    /// Retained for source compatibility. The top fade is applied once at the main-window level.
    /// - Parameter height: The height of the fade overlay.
    /// - Returns: The view unchanged.
    func topFade(height: CGFloat = 96) -> some View {
        modifier(TopFadeModifier(height: height))
    }
}
