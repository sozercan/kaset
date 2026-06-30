import SwiftUI

// MARK: - PlayerBarProgressLane

struct PlayerBarProgressLane: View {
    let fraction: Double
    let accent: Color
    let elapsedText: String
    let remainingText: String
    let isLive: Bool
    let canSeek: Bool
    let isLoading: Bool
    let onScrub: (Double) -> Void
    let onCommit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragging = false
    @State private var isHovering = false

    private var clampedFraction: CGFloat {
        CGFloat(min(max(0, self.fraction), 1))
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(self.isLive ? String(localized: "LIVE") : self.elapsedText)
                    .foregroundStyle(self.isLive ? .red : .secondary)

                Spacer(minLength: 8)

                Text(self.isLive ? "" : self.remainingText)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .lineLimit(1)
            .frame(height: 12)

            self.progressBar
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Playback position"))
        .accessibilityValue(self.isLive ? String(localized: "Live stream") : "\(self.elapsedText), \(self.remainingText)")
        .accessibilityAdjustableAction { direction in
            guard self.canSeek else { return }
            switch direction {
            case .increment:
                self.nudge(by: 0.02)
            case .decrement:
                self.nudge(by: -0.02)
            @unknown default:
                break
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fillWidth = width * self.clampedFraction
            let thumbDiameter = PlayerBarSliderVisuals.thumbDiameter(
                isHovering: self.isHovering,
                isDragging: self.isDragging
            )
            let fillColor = self.isLoading ? self.loadingFillColor : self.accent
            let thumbColor = self.isLoading ? self.loadingThumbColor : self.accent

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(self.trackColor)
                    .frame(height: PlayerBarSliderVisuals.trackThickness)

                UnevenRoundedRectangle(
                    topLeadingRadius: 999,
                    bottomLeadingRadius: 999
                )
                .fill(fillColor)
                .frame(width: fillWidth, height: PlayerBarSliderVisuals.trackThickness)
                .opacity(self.isLive ? 0 : 1)

                if self.isLoading {
                    PlayerBarSliderLoadingShimmer(
                        colorScheme: self.colorScheme,
                        reduceMotion: self.reduceMotion
                    )
                    .frame(height: PlayerBarSliderVisuals.trackThickness)
                    .transition(.opacity)
                }

                Circle()
                    .fill(thumbColor)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .offset(
                        x: min(max(0, fillWidth - thumbDiameter / 2), max(0, width - thumbDiameter)),
                        y: PlayerBarSliderVisuals.trackThickness / 2 - thumbDiameter / 2
                    )
                    .opacity(self.canSeek ? 1 : 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .animation(PlayerBarSliderVisuals.trackAnimation, value: self.isHovering)
            .animation(PlayerBarSliderVisuals.thumbAnimation, value: self.isDragging)
            .animation(PlayerBarSliderVisuals.thumbAnimation, value: self.isHovering)
            .animation(.easeInOut(duration: 0.18), value: self.isLoading)
            .padding(PlayerBarSliderVisuals.hitOutset)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard self.canSeek, width > 0 else { return }
                        self.isDragging = true
                        let x = value.location.x - PlayerBarSliderVisuals.hitOutset
                        let fraction = Double(min(max(0, x / width), 1))
                        self.onScrub(fraction)
                    }
                    .onEnded { _ in
                        guard self.canSeek else { return }
                        self.isDragging = false
                        self.onCommit()
                    }
            )
            .padding(-PlayerBarSliderVisuals.hitOutset)
            .onHover { hovering in
                self.isHovering = hovering
            }
        }
        .frame(height: 12)
    }

    private func nudge(by delta: Double) {
        self.onScrub(min(1, max(0, self.fraction + delta)))
        self.onCommit()
    }

    private var trackColor: Color {
        PlayerBarSliderVisuals.trackColor(
            colorScheme: self.colorScheme,
            isActive: !self.isLoading && (self.isHovering || self.isDragging)
        )
    }

    private var loadingFillColor: Color {
        PlayerBarSliderVisuals.loadingFillColor(colorScheme: self.colorScheme)
    }

    private var loadingThumbColor: Color {
        PlayerBarSliderVisuals.loadingThumbColor(colorScheme: self.colorScheme)
    }
}
