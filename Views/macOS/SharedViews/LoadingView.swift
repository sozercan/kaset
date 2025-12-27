import SwiftUI

// MARK: - FixedProgressView

/// A ProgressView wrapper with explicit frame sizing to prevent AppKit Auto Layout constraint warnings.
/// The standard ProgressView on macOS can produce spurious warnings like:
/// "has a maximum length that doesn't satisfy min <= max"
/// This wrapper provides a fixed frame to avoid these layout ambiguity issues.
struct FixedProgressView: View {
    let controlSize: ControlSize
    let scale: CGFloat

    init(controlSize: ControlSize = .regular, scale: CGFloat = 1.0) {
        self.controlSize = controlSize
        self.scale = scale
    }

    private var frameSize: CGFloat {
        switch self.controlSize {
        case .mini:
            return 12 * self.scale
        case .small:
            return 16 * self.scale
        case .regular:
            return 20 * self.scale
        case .large:
            return 24 * self.scale
        case .extraLarge:
            return 32 * self.scale
        @unknown default:
            return 20 * self.scale
        }
    }

    var body: some View {
        ProgressView()
            .controlSize(self.controlSize)
            .scaleEffect(self.scale)
            .frame(width: self.frameSize, height: self.frameSize)
    }
}

// MARK: - LoadingView

/// Reusable loading indicator view with optional message.
/// Includes a pulsing animation for visual feedback.
struct LoadingView: View {
    let message: String

    /// Whether to show skeleton placeholders instead of just a spinner.
    let showSkeleton: Bool

    /// Number of skeleton sections to show.
    let skeletonSectionCount: Int

    init(
        _ message: String = "Loading...",
        showSkeleton: Bool = false,
        skeletonSectionCount: Int = 3
    ) {
        self.message = message
        self.showSkeleton = showSkeleton
        self.skeletonSectionCount = skeletonSectionCount
    }

    var body: some View {
        if self.showSkeleton {
            self.skeletonContent
        } else {
            self.spinnerContent
        }
    }

    private var spinnerContent: some View {
        VStack(spacing: 16) {
            FixedProgressView(controlSize: .regular)
            Text(self.message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var skeletonContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(0 ..< self.skeletonSectionCount, id: \.self) { _ in
                    SkeletonSectionView()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }
}

// MARK: - HomeLoadingView

/// A specialized loading view for the home screen with skeleton sections.
@available(macOS 26.0, *)
struct HomeLoadingView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(0 ..< 4, id: \.self) { index in
                    SkeletonSectionView()
                        .fadeIn(delay: Double(index) * 0.1)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }
}

#Preview {
    VStack {
        LoadingView("Loading your music...")
        Divider()
        LoadingView("Loading...", showSkeleton: true, skeletonSectionCount: 2)
    }
    .frame(width: 600, height: 800)
}
