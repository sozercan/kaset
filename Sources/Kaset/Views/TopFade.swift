import SwiftUI

struct TopFade: View {
    enum Style {
        case background
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
                Color.black.opacity(0.30),
                Color.black.opacity(0.18),
                Color.black.opacity(0.05),
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

private struct TopFadeMask: View {
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.28), Color.black],
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

extension View {
    func topFade(height: CGFloat = 96, style: TopFade.Style = .background) -> some View {
        modifier(TopFadeModifier(height: height, style: style))
    }
}
