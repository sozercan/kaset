import SwiftUI

// MARK: - PlayerBarSliderLoadingShimmer

struct PlayerBarSliderLoadingShimmer: View {
    let colorScheme: ColorScheme
    let reduceMotion: Bool

    @State private var isAnimating = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let bandWidth = max(42, width * 0.34)

            Capsule()
                .fill(Color.clear)
                .overlay(alignment: .leading) {
                    LinearGradient(
                        colors: [
                            Color.clear,
                            self.shimmerColor.opacity(self.reduceMotion ? 0.28 : 0.08),
                            self.shimmerColor.opacity(self.reduceMotion ? 0.42 : 0.40),
                            self.shimmerColor.opacity(self.reduceMotion ? 0.28 : 0.08),
                            Color.clear,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: bandWidth)
                    .offset(x: self.reduceMotion ? (width - bandWidth) / 2 : self.shimmerOffset(width: width, bandWidth: bandWidth))
                }
                .clipShape(.capsule)
                .onAppear {
                    guard !self.reduceMotion else { return }
                    self.isAnimating = false
                    withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) {
                        self.isAnimating = true
                    }
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var shimmerColor: Color {
        self.colorScheme == .dark ? .white : .black
    }

    private func shimmerOffset(width: CGFloat, bandWidth: CGFloat) -> CGFloat {
        self.isAnimating ? width + bandWidth * 0.25 : -bandWidth * 1.25
    }
}
