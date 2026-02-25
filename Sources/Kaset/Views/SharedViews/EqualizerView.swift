import SwiftUI

// MARK: - EqualizerView

/// An animated equalizer view that shows audio levels, commonly used as a "now playing" indicator.
/// Displays animated bars that move up and down to simulate audio visualization.
@available(macOS 26.0, *)
struct EqualizerView: View {
    /// Whether the equalizer is animating (playing state).
    var isAnimating: Bool

    /// Number of bars to display.
    var barCount: Int = 3

    /// Spacing between bars.
    var spacing: CGFloat = 2

    /// Bar width.
    var barWidth: CGFloat = 3

    /// Bar corner radius.
    var cornerRadius: CGFloat = 1.5

    /// Bar color.
    var color: Color = .red

    var body: some View {
        HStack(spacing: self.spacing) {
            ForEach(0 ..< self.barCount, id: \.self) { index in
                EqualizerBar(
                    isAnimating: self.isAnimating,
                    barIndex: index,
                    barWidth: self.barWidth,
                    cornerRadius: self.cornerRadius,
                    color: self.color
                )
            }
        }
    }
}

// MARK: - EqualizerBar

/// A single animated bar in the equalizer.
@available(macOS 26.0, *)
private struct EqualizerBar: View {
    let isAnimating: Bool
    let barIndex: Int
    let barWidth: CGFloat
    let cornerRadius: CGFloat
    let color: Color

    /// Each bar has different timing for natural look.
    private var animationDelay: Double {
        Double(self.barIndex) * 0.15
    }

    /// Each bar has different duration for variety.
    private var animationDuration: Double {
        switch self.barIndex % 3 {
        case 0: 0.4
        case 1: 0.5
        default: 0.35
        }
    }

    /// Height range for each bar varies.
    private var minHeight: CGFloat {
        switch self.barIndex % 3 {
        case 0: 0.15
        case 1: 0.2
        default: 0.1
        }
    }

    private var maxHeight: CGFloat {
        switch self.barIndex % 3 {
        case 0: 0.9
        case 1: 1.0
        default: 0.75
        }
    }

    @State private var heightFraction: CGFloat = 0.3

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: self.cornerRadius)
                .fill(self.color)
                .frame(width: self.barWidth, height: geometry.size.height * self.heightFraction)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(width: self.barWidth)
        .onAppear {
            self.startAnimation()
        }
        .onChange(of: self.isAnimating) { _, newValue in
            if newValue {
                self.startAnimation()
            } else {
                self.stopAnimation()
            }
        }
    }

    private func startAnimation() {
        guard self.isAnimating else {
            self.heightFraction = self.minHeight
            return
        }

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            self.heightFraction = 0.5
            return
        }

        // Initial delay for staggered start
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(self.animationDelay))
            guard self.isAnimating else { return }
            withAnimation(
                .easeInOut(duration: self.animationDuration)
                    .repeatForever(autoreverses: true)
            ) {
                self.heightFraction = self.maxHeight
            }
        }
    }

    private func stopAnimation() {
        withAnimation(.easeOut(duration: 0.3)) {
            self.heightFraction = self.minHeight
        }
    }
}

// MARK: - NowPlayingIndicator

/// A compact now-playing indicator that shows equalizer when playing, or a static icon when paused.
@available(macOS 26.0, *)
struct NowPlayingIndicator: View {
    var isPlaying: Bool
    var size: CGFloat = 16

    var body: some View {
        Group {
            if self.isPlaying {
                EqualizerView(
                    isAnimating: true,
                    barCount: 3,
                    spacing: 2,
                    barWidth: 3,
                    cornerRadius: 1.5,
                    color: .red
                )
            } else {
                Image(systemName: "speaker.fill")
                    .font(.system(size: self.size * 0.7))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: self.size, height: self.size)
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview {
    VStack(spacing: 24) {
        // Playing state
        HStack(spacing: 24) {
            Text("Playing:")
            EqualizerView(isAnimating: true)
                .frame(width: 20, height: 20)
        }

        // Paused state
        HStack(spacing: 24) {
            Text("Paused:")
            EqualizerView(isAnimating: false)
                .frame(width: 20, height: 20)
        }

        // Now Playing Indicator
        HStack(spacing: 24) {
            NowPlayingIndicator(isPlaying: true)
            NowPlayingIndicator(isPlaying: false)
        }

        // Larger version
        EqualizerView(isAnimating: true, barCount: 5, spacing: 3, barWidth: 4)
            .frame(width: 40, height: 30)
    }
    .padding()
}
