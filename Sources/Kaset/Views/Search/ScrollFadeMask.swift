import SwiftUI

// MARK: - VerticalScrollFade

/// Adds top and bottom fade masks to a vertical `ScrollView`, each shown only at
/// the edge that is actually scrollable: the top fade hides when scrolled to the
/// top, the bottom fade hides when scrolled to the bottom, and both show while in
/// the middle. Text under a fade dissolves to zero opacity.
///
/// Uses the native `onScrollGeometryChange` observer (macOS 15+), no manual
/// offset preferences or overlays.
struct VerticalScrollFade: ViewModifier {
    var fadeHeight: CGFloat = 22

    @State private var showTopFade = false
    @State private var showBottomFade = false

    private struct ScrollEdges: Equatable {
        let atTop: Bool
        let atBottom: Bool
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
                let topThreshold = geometry.contentInsets.top + 1
                let atTop = geometry.contentOffset.y <= topThreshold
                let maxOffset = geometry.contentSize.height
                    - geometry.containerSize.height
                    + geometry.contentInsets.bottom
                let atBottom = geometry.contentOffset.y >= maxOffset - 1
                return ScrollEdges(atTop: atTop, atBottom: atBottom)
            } action: { _, edges in
                self.showTopFade = !edges.atTop
                self.showBottomFade = !edges.atBottom
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: self.showTopFade ? self.fadeHeight : 0)

                    Rectangle().fill(.black)

                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: self.showBottomFade ? self.fadeHeight : 0)
                }
                .animation(.easeInOut(duration: 0.18), value: self.showTopFade)
                .animation(.easeInOut(duration: 0.18), value: self.showBottomFade)
            }
    }
}

extension View {
    /// Fades the top/bottom edges of a vertical scroll view only when that edge
    /// is scrollable. Apply to the `ScrollView` itself.
    func verticalScrollFade(fadeHeight: CGFloat = 22) -> some View {
        self.modifier(VerticalScrollFade(fadeHeight: fadeHeight))
    }
}
