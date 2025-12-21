import SwiftUI

// MARK: - SkeletonView

/// A skeleton loading placeholder with shimmer animation.
/// Use this to indicate content is loading while maintaining layout structure.
struct SkeletonView: View {
    /// The shape of the skeleton element.
    enum Shape {
        case rectangle(cornerRadius: CGFloat)
        case circle
        case capsule
    }

    let shape: Shape

    @State private var isAnimating = false

    /// Gradient for shimmer effect.
    private var shimmerGradient: LinearGradient {
        LinearGradient(
            colors: [
                .primary.opacity(0.08),
                .primary.opacity(0.15),
                .primary.opacity(0.08),
            ],
            startPoint: self.isAnimating ? .trailing : .leading,
            endPoint: self.isAnimating ? .init(x: 2, y: 0) : .trailing
        )
    }

    var body: some View {
        Group {
            switch self.shape {
            case let .rectangle(cornerRadius):
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.quaternary)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(self.shimmerGradient)
                    )
            case .circle:
                Circle()
                    .fill(.quaternary)
                    .overlay(
                        Circle()
                            .fill(self.shimmerGradient)
                    )
            case .capsule:
                Capsule()
                    .fill(.quaternary)
                    .overlay(
                        Capsule()
                            .fill(self.shimmerGradient)
                    )
            }
        }
        .onAppear {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            withAnimation(
                .easeInOut(duration: 1.5)
                    .repeatForever(autoreverses: false)
            ) {
                self.isAnimating = true
            }
        }
    }
}

// MARK: - Convenience Initializers

extension SkeletonView {
    /// Rectangle skeleton with optional corner radius.
    static func rectangle(cornerRadius: CGFloat = 8) -> SkeletonView {
        SkeletonView(shape: .rectangle(cornerRadius: cornerRadius))
    }

    /// Circle skeleton for avatars/thumbnails.
    static var circle: SkeletonView {
        SkeletonView(shape: .circle)
    }

    /// Capsule skeleton for tags/chips.
    static var capsule: SkeletonView {
        SkeletonView(shape: .capsule)
    }
}

// MARK: - SkeletonCardView

/// A skeleton placeholder for card layouts (thumbnail + text).
struct SkeletonCardView: View {
    let width: CGFloat
    let height: CGFloat

    init(width: CGFloat = 160, height: CGFloat = 160) {
        self.width = width
        self.height = height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail skeleton
            SkeletonView.rectangle(cornerRadius: 8)
                .frame(width: self.width, height: self.height)

            // Title skeleton
            SkeletonView.rectangle(cornerRadius: 4)
                .frame(width: self.width * 0.8, height: 14)

            // Subtitle skeleton
            SkeletonView.rectangle(cornerRadius: 4)
                .frame(width: self.width * 0.5, height: 12)
        }
    }
}

// MARK: - SkeletonRowView

/// A skeleton placeholder for list rows.
struct SkeletonRowView: View {
    var showThumbnail: Bool = true
    var thumbnailSize: CGFloat = 48

    var body: some View {
        HStack(spacing: 12) {
            if self.showThumbnail {
                SkeletonView.rectangle(cornerRadius: 6)
                    .frame(width: self.thumbnailSize, height: self.thumbnailSize)
            }

            VStack(alignment: .leading, spacing: 6) {
                SkeletonView.rectangle(cornerRadius: 4)
                    .frame(height: 14)

                SkeletonView.rectangle(cornerRadius: 4)
                    .frame(width: 120, height: 12)
            }

            Spacer()

            SkeletonView.rectangle(cornerRadius: 4)
                .frame(width: 45, height: 12)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 24)
    }
}

// MARK: - SkeletonSectionView

/// A skeleton placeholder for a horizontal section (like home sections).
struct SkeletonSectionView: View {
    let cardCount: Int
    let cardWidth: CGFloat
    let cardHeight: CGFloat

    init(cardCount: Int = 5, cardWidth: CGFloat = 160, cardHeight: CGFloat = 160) {
        self.cardCount = cardCount
        self.cardWidth = cardWidth
        self.cardHeight = cardHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section title skeleton
            SkeletonView.rectangle(cornerRadius: 4)
                .frame(width: 150, height: 20)

            // Cards
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(0 ..< self.cardCount, id: \.self) { _ in
                        SkeletonCardView(width: self.cardWidth, height: self.cardHeight)
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 32) {
        // Individual skeletons
        HStack(spacing: 16) {
            SkeletonView.rectangle()
                .frame(width: 100, height: 100)

            SkeletonView.circle
                .frame(width: 60, height: 60)

            SkeletonView.capsule
                .frame(width: 80, height: 30)
        }

        // Card skeleton
        SkeletonCardView()

        // Row skeleton
        SkeletonRowView()
            .frame(maxWidth: 400)

        // Section skeleton
        SkeletonSectionView(cardCount: 3)
    }
    .padding()
    .frame(width: 600)
}
