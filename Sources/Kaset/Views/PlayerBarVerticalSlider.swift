import SwiftUI

// MARK: - PlayerBarVerticalSlider

struct PlayerBarVerticalSlider: View {
    @Binding var value: Double

    let accent: Color
    let accessibilityIdentifier: String?
    let accessibilityLabel: String
    let onEditingChanged: (Bool) -> Void
    let onValueChanged: (_ oldValue: Double, _ newValue: Double) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragging = false

    private var clampedValue: CGFloat {
        CGFloat(min(max(0, self.value), 1))
    }

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let fillHeight = height * self.clampedValue
            let thumbDiameter: CGFloat = 12

            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(self.trackColor)
                    .frame(width: 4)

                UnevenRoundedRectangle(
                    bottomLeadingRadius: 999,
                    bottomTrailingRadius: 999
                )
                .fill(self.accent)
                .frame(width: 4, height: fillHeight)

                Circle()
                    .fill(self.accent)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .offset(y: -min(max(0, fillHeight - thumbDiameter / 2), max(0, height - thumbDiameter)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        self.beginEditingIfNeeded()
                        self.updateValue(from: drag.location.y, height: height)
                    }
                    .onEnded { _ in
                        self.endEditingIfNeeded()
                    }
            )
        }
        .frame(width: 28, height: 122)
        .playerBarVerticalSliderAccessibilityIdentifier(self.accessibilityIdentifier)
        .accessibilityLabel(self.accessibilityLabel)
        .accessibilityValue("\(Int(self.clampedValue * 100))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                self.adjustValue(by: 0.05)
            case .decrement:
                self.adjustValue(by: -0.05)
            @unknown default:
                break
            }
        }
    }

    private func beginEditingIfNeeded() {
        guard !self.isDragging else { return }
        self.isDragging = true
        self.onEditingChanged(true)
    }

    private func endEditingIfNeeded() {
        guard self.isDragging else { return }
        self.isDragging = false
        self.onEditingChanged(false)
    }

    private func updateValue(from locationY: CGFloat, height: CGFloat) {
        guard height > 0 else { return }
        self.setValue(1 - Double(min(max(0, locationY / height), 1)))
    }

    private func adjustValue(by delta: Double) {
        let clamped = min(max(0, self.value + delta), 1)
        guard self.value != clamped else { return }
        self.beginEditingIfNeeded()
        self.setValue(clamped)
        self.endEditingIfNeeded()
    }

    private func setValue(_ newValue: Double) {
        let oldValue = self.value
        let clamped = min(max(0, newValue), 1)
        guard oldValue != clamped else { return }
        self.value = clamped
        self.onValueChanged(oldValue, clamped)
    }

    private var trackColor: Color {
        self.colorScheme == .dark ? .white.opacity(0.18) : .black.opacity(0.18)
    }
}

// MARK: - Accessibility Helpers

private extension View {
    @ViewBuilder
    func playerBarVerticalSliderAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            self.accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
