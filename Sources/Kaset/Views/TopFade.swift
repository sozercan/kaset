import SwiftUI

// MARK: - TopFade

/// A lightweight top overlay that fades scrolling content beneath hidden toolbar backgrounds.
@available(macOS 26.0, *)
struct TopFade: View {
    enum Style {
        /// Fades plain pages with the existing painted scrim overlay.
        case background
        /// Fades foreground content only, leaving custom backgrounds untouched.
        case contentMask
    }

    let height: CGFloat
    let style: Style

    var body: some View {
        LinearGradient(
            colors: self.colors,
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: self.height)
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var colors: [Color] {
        switch self.style {
        case .background:
            [
                Color.black.opacity(0.42),
                Color.black.opacity(0.26),
                Color.black.opacity(0.08),
                Color.clear,
            ]
        case .contentMask:
            [
                Color.clear,
                Color.clear,
            ]
        }
    }
}

// MARK: - TopFadeMask

/// A mask that makes foreground content transparent at the top edge.
@available(macOS 26.0, *)
private struct TopFadeMask: View {
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.clear, Color.black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: min(self.height, proxy.size.height))

                Rectangle()
                    .fill(Color.black)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - TopFadeModifier

@available(macOS 26.0, *)
struct TopFadeModifier: ViewModifier {
    let height: CGFloat
    let style: TopFade.Style

    func body(content: Content) -> some View {
        switch self.style {
        case .background:
            content
                .overlay(alignment: .top) {
                    TopFade(height: self.height, style: self.style)
                }
        case .contentMask:
            content
                .mask {
                    TopFadeMask(height: self.height)
                }
        }
    }
}

@available(macOS 26.0, *)
extension View {
    /// Adds the same top fade treatment used by toolbar-backed pages when the toolbar background is hidden.
    /// - Parameters:
    ///   - height: The height of the fade treatment.
    ///   - style: The fade treatment to use for the page background.
    /// - Returns: A view with a non-interactive top fade treatment.
    func topFade(height: CGFloat = 96, style: TopFade.Style = .background) -> some View {
        modifier(TopFadeModifier(height: height, style: style))
    }
}
