import SwiftUI

struct InteractiveCardStyle: ButtonStyle {
    var showShadow: Bool = true

    var hoverScale: CGFloat = 1.02

    var pressScale: CGFloat = 0.98

    var hapticFeedback: HapticService.FeedbackType?

    @State private var isHovering = false

    private var tracksHover: Bool {
        self.showShadow || self.hoverScale != 1
    }

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .scaleEffect(configuration.isPressed ? self.pressScale : (self.isHovering ? self.hoverScale : 1.0))
            .shadow(
                color: self.showShadow && self.isHovering ? .black.opacity(0.15) : .clear,
                radius: self.isHovering ? 12 : 0,
                x: 0,
                y: self.isHovering ? 4 : 0
            )
            .animation(AppAnimation.spring, value: configuration.isPressed)
            .animation(AppAnimation.spring, value: self.isHovering)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed, let feedback = hapticFeedback {
                    HapticService.perform(feedback)
                }
            }

        if self.tracksHover {
            label.onHover { hovering in
                self.isHovering = hovering
            }
        } else {
            label
        }
    }
}

struct InteractiveRowStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8

    var hoverColor: Color = .primary.opacity(0.06)

    var hapticFeedback: HapticService.FeedbackType?

    var isHovered: Bool?

    @State private var isHovering = false

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if self.isHovered == nil {
            self.highlightedLabel(configuration, isHovered: self.isHovering)
                .onHover { hovering in
                    self.isHovering = hovering
                }
        } else {
            self.highlightedLabel(configuration, isHovered: self.isHovered == true)
        }
    }

    private func highlightedLabel(_ configuration: Configuration, isHovered: Bool) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: self.cornerRadius)
                    .fill(isHovered || configuration.isPressed ? self.hoverColor : .clear)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(AppAnimation.quick, value: configuration.isPressed)
            .animation(AppAnimation.quick, value: isHovered)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed, let feedback = hapticFeedback {
                    HapticService.perform(feedback)
                }
            }
    }
}

struct PressableButtonStyle: ButtonStyle {
    var pressScale: CGFloat = 0.9

    var hapticFeedback: HapticService.FeedbackType?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? self.pressScale : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(AppAnimation.quick, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed, let feedback = hapticFeedback {
                    HapticService.perform(feedback)
                }
            }
    }
}

struct ChipButtonStyle: ButtonStyle {
    var isSelected: Bool

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : (self.isHovering ? 1.03 : 1.0))
            .animation(AppAnimation.spring, value: configuration.isPressed)
            .animation(AppAnimation.spring, value: self.isHovering)
            .onHover { hovering in
                self.isHovering = hovering
            }
    }
}

extension ButtonStyle where Self == InteractiveCardStyle {
    static var interactiveCard: InteractiveCardStyle {
        InteractiveCardStyle()
    }

    static func interactiveCard(
        showShadow: Bool = true,
        hoverScale: CGFloat = 1.02,
        pressScale: CGFloat = 0.98,
        hapticFeedback: HapticService.FeedbackType? = nil
    ) -> InteractiveCardStyle {
        InteractiveCardStyle(
            showShadow: showShadow,
            hoverScale: hoverScale,
            pressScale: pressScale,
            hapticFeedback: hapticFeedback
        )
    }
}

extension ButtonStyle where Self == InteractiveRowStyle {
    static var interactiveRow: InteractiveRowStyle {
        InteractiveRowStyle()
    }

    static func interactiveRow(
        cornerRadius: CGFloat = 8,
        hapticFeedback: HapticService.FeedbackType? = nil,
        isHovered: Bool? = nil
    ) -> InteractiveRowStyle {
        InteractiveRowStyle(cornerRadius: cornerRadius, hapticFeedback: hapticFeedback, isHovered: isHovered)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle {
        PressableButtonStyle()
    }

    static func pressable(hapticFeedback: HapticService.FeedbackType?) -> PressableButtonStyle {
        PressableButtonStyle(hapticFeedback: hapticFeedback)
    }
}

extension ButtonStyle where Self == ChipButtonStyle {
    static func chip(isSelected: Bool) -> ChipButtonStyle {
        ChipButtonStyle(isSelected: isSelected)
    }
}

#Preview {
    VStack(spacing: 20) {
        Button {} label: {
            VStack {
                Rectangle()
                    .fill(.blue.gradient)
                    .frame(width: 120, height: 120)
                    .clipShape(.rect(cornerRadius: 8))
                Text("Card")
                    .font(.caption)
            }
        }
        .buttonStyle(.interactiveCard)

        Button {} label: {
            HStack {
                Circle()
                    .fill(.green)
                    .frame(width: 40, height: 40)
                Text("List Row")
                Spacer()
            }
            .padding(8)
        }
        .buttonStyle(.interactiveRow)
        .frame(width: 200)

        Button {} label: {
            Image(systemName: "play.fill")
                .font(.title)
        }
        .buttonStyle(.pressable)
    }
    .padding()
}
