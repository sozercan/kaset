import SwiftUI

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
            ProgressView()
                .pulse(minScale: 0.95, maxScale: 1.05, duration: 1.2)
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

// MARK: - ListLoadingView

/// A specialized loading view for list screens with skeleton rows.
struct ListLoadingView: View {
    let rowCount: Int

    init(rowCount: Int = 8) {
        self.rowCount = rowCount
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0 ..< self.rowCount, id: \.self) { _ in
                    SkeletonRowView()
                    Divider()
                        .padding(.leading, 72)
                }
            }
            .padding(.vertical, 8)
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
