import SwiftUI

// MARK: - AppleMusicScrubber

/// Apple Music-style hover scrubber: a row of elapsed / remaining timestamps at
/// the far edges, above a long full-width draggable progress bar. Shown (by the
/// parent) over the blurred track info while the now-playing area is hovered, so
/// it is always in its full form — the parent controls visibility (opacity) and
/// interactivity (`isInteractive`).
struct AppleMusicScrubber: View {
    /// Outer height reserved for the two-row lane (timestamps + bar).
    static let laneHeight: CGFloat = 30

    /// Current playback fraction (0...1) to render as the filled portion.
    let fraction: Double
    /// Accent colour for the filled track and thumb.
    let accent: Color
    /// Pre-formatted elapsed time (e.g. "1:23").
    let elapsedText: String
    /// Pre-formatted remaining time (e.g. "-2:05").
    let remainingText: String
    /// Whether the control accepts pointer/keyboard input (true while hovered).
    let isInteractive: Bool
    /// Called continuously while dragging with the new fraction (0...1).
    let onScrub: (Double) -> Void
    /// Called when the drag ends, to commit the seek.
    let onCommit: () -> Void

    @FocusState private var isFocused: Bool

    /// Fraction nudge per arrow-key press / accessibility adjustment.
    private var keyboardStep: Double {
        0.02
    }

    private var barHeight: CGFloat {
        5
    }

    private var thumbDiameter: CGFloat {
        11
    }

    private var clampedFraction: CGFloat {
        CGFloat(min(max(0, self.fraction), 1))
    }

    var body: some View {
        VStack(spacing: 4) {
            // Timestamps at the far edges.
            HStack(spacing: 8) {
                Text(self.elapsedText)

                Spacer(minLength: 8)

                Text(self.remainingText)
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)

            // Long, full-width draggable bar.
            GeometryReader { proxy in
                let width = proxy.size.width
                let fillWidth = width * self.clampedFraction

                ZStack(alignment: .leading) {
                    // Background track.
                    Capsule()
                        .fill(.primary.opacity(0.22))
                        .frame(height: self.barHeight)

                    // Elapsed fill.
                    Capsule()
                        .fill(self.accent)
                        .frame(width: fillWidth, height: self.barHeight)

                    // Draggable thumb.
                    Circle()
                        .fill(self.accent)
                        .frame(width: self.thumbDiameter, height: self.thumbDiameter)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                        .offset(x: min(max(0, fillWidth - self.thumbDiameter / 2), max(0, width - self.thumbDiameter)))
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard width > 0 else { return }
                            let fraction = Double(min(max(0, value.location.x / width), 1))
                            self.onScrub(fraction)
                        }
                        .onEnded { _ in
                            self.onCommit()
                        }
                )
            }
            .frame(height: 12)
        }
        .frame(height: Self.laneHeight)
        .focusable(self.isInteractive)
        .focused(self.$isFocused)
        .onKeyPress(.leftArrow) {
            guard self.isInteractive else { return .ignored }
            self.nudge(by: -self.keyboardStep)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard self.isInteractive else { return .ignored }
            self.nudge(by: self.keyboardStep)
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Playback position"))
        .accessibilityValue("\(self.elapsedText), \(self.remainingText)")
        .accessibilityAdjustableAction { direction in
            guard self.isInteractive else { return }
            switch direction {
            case .increment:
                self.nudge(by: self.keyboardStep)
            case .decrement:
                self.nudge(by: -self.keyboardStep)
            @unknown default:
                break
            }
        }
        // When idle the scrubber is visually hidden behind the track info; keep
        // it out of the accessibility tree too so VoiceOver can't seek invisibly.
        .accessibilityHidden(!self.isInteractive)
    }

    /// Move the playback fraction by `delta` (clamped) and commit the seek.
    private func nudge(by delta: Double) {
        self.onScrub(min(1, max(0, self.fraction + delta)))
        self.onCommit()
    }
}

// MARK: - IdleProgressLine

/// A slim, low-contrast full-width progress indicator shown in the player bar
/// when the now-playing area is idle (not hovered). Purely decorative — the
/// interactive seeking lives in `AppleMusicScrubber`.
struct IdleProgressLine: View {
    /// Current playback fraction (0...1).
    let fraction: Double

    private var clampedFraction: CGFloat {
        CGFloat(min(max(0, self.fraction), 1))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fillWidth = width * self.clampedFraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.5))
                    .frame(height: 4)

                Capsule()
                    .fill(.primary)
                    .frame(width: fillWidth, height: 4)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
