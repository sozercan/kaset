import SwiftUI

// MARK: - SkeletonView

/// A skeleton loading placeholder with shimmer animation.
/// Use this to indicate content is loading while maintaining layout structure.
/// Uses TimelineView for smooth, stutter-free continuous animation.
struct SkeletonView: View {
    /// The shape of the skeleton element.
    enum Shape {
        case rectangle(cornerRadius: CGFloat)
        case circle
        case capsule
    }

    let shape: Shape

    private let animationDuration: Double = 1.5

    private var shouldAnimate: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Gradient for shimmer effect based on animation progress.
    private func shimmerGradient(progress: Double) -> LinearGradient {
        // Progress goes from 0 to 1, we map it to gradient positions
        let startX = -1.0 + progress * 3.0
        let endX = startX + 1.0
        return LinearGradient(
            colors: [
                .primary.opacity(0.08),
                .primary.opacity(0.18),
                .primary.opacity(0.08),
            ],
            startPoint: UnitPoint(x: startX, y: 0),
            endPoint: UnitPoint(x: endX, y: 0)
        )
    }

    /// Static gradient for reduced motion.
    private var staticGradient: some ShapeStyle {
        Color.primary.opacity(0.1)
    }

    var body: some View {
        if self.shouldAnimate {
            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let progress = elapsed.truncatingRemainder(dividingBy: self.animationDuration) / self.animationDuration
                self.shapeView(gradient: self.shimmerGradient(progress: progress))
            }
        } else {
            self.shapeView(gradient: self.staticGradient)
        }
    }

    @ViewBuilder
    private func shapeView(gradient: some ShapeStyle) -> some View {
        switch self.shape {
        case let .rectangle(cornerRadius):
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.quaternary)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(gradient)
                )
        case .circle:
            Circle()
                .fill(.quaternary)
                .overlay(
                    Circle()
                        .fill(gradient)
                )
        case .capsule:
            Capsule()
                .fill(.quaternary)
                .overlay(
                    Capsule()
                        .fill(gradient)
                )
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
