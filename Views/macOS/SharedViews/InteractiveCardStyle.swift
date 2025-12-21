import SwiftUI

// MARK: - InteractiveCardStyle

/// A button style that provides hover and press feedback for card-like elements.
/// Scales up on hover, scales down on press, and shows a subtle shadow.
@available(macOS 26.0, *)
struct InteractiveCardStyle: ButtonStyle {
    /// Whether to show shadow on hover.
    var showShadow: Bool = true

    /// Scale factor when hovering.
    var hoverScale: CGFloat = 1.02

    /// Scale factor when pressed.
    var pressScale: CGFloat = 0.98

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? self.pressScale : (self.isHovering ? self.hoverScale : 1.0))
            .shadow(
                color: self.showShadow && self.isHovering ? .black.opacity(0.15) : .clear,
                radius: self.isHovering ? 12 : 0,
                x: 0,
                y: self.isHovering ? 4 : 0
            )
            .animation(AppAnimation.spring, value: configuration.isPressed)
            .animation(AppAnimation.spring, value: self.isHovering)
            .onHover { hovering in
                self.isHovering = hovering
            }
    }
}

// MARK: - InteractiveRowStyle

/// A button style for list rows with hover background highlight.
@available(macOS 26.0, *)
struct InteractiveRowStyle: ButtonStyle {
    /// Corner radius for the hover background.
    var cornerRadius: CGFloat = 8

    /// Hover background color.
    var hoverColor: Color = .primary.opacity(0.06)

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: self.cornerRadius)
                    .fill(self.isHovering || configuration.isPressed ? self.hoverColor : .clear)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(AppAnimation.quick, value: configuration.isPressed)
            .animation(AppAnimation.quick, value: self.isHovering)
            .onHover { hovering in
                self.isHovering = hovering
            }
    }
}

// MARK: - PressableButtonStyle

/// A button style that provides subtle press feedback for icon buttons.
@available(macOS 26.0, *)
struct PressableButtonStyle: ButtonStyle {
    /// Scale factor when pressed.
    var pressScale: CGFloat = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? self.pressScale : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(AppAnimation.quick, value: configuration.isPressed)
    }
}

// MARK: - ChipButtonStyle

/// A button style for filter chips with scale and background animation.
@available(macOS 26.0, *)
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

// MARK: - Button Style Extensions

@available(macOS 26.0, *)
extension ButtonStyle where Self == InteractiveCardStyle {
    /// Interactive card style with hover scale and shadow effects.
    static var interactiveCard: InteractiveCardStyle { InteractiveCardStyle() }

    /// Interactive card style with custom parameters.
    static func interactiveCard(
        showShadow: Bool = true,
        hoverScale: CGFloat = 1.02,
        pressScale: CGFloat = 0.98
    ) -> InteractiveCardStyle {
        InteractiveCardStyle(showShadow: showShadow, hoverScale: hoverScale, pressScale: pressScale)
    }
}

@available(macOS 26.0, *)
extension ButtonStyle where Self == InteractiveRowStyle {
    /// Interactive row style with hover background.
    static var interactiveRow: InteractiveRowStyle { InteractiveRowStyle() }

    /// Interactive row style with custom corner radius.
    static func interactiveRow(cornerRadius: CGFloat = 8) -> InteractiveRowStyle {
        InteractiveRowStyle(cornerRadius: cornerRadius)
    }
}

@available(macOS 26.0, *)
extension ButtonStyle where Self == PressableButtonStyle {
    /// Pressable button style with scale feedback.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

@available(macOS 26.0, *)
extension ButtonStyle where Self == ChipButtonStyle {
    /// Chip button style for filter chips.
    static func chip(isSelected: Bool) -> ChipButtonStyle {
        ChipButtonStyle(isSelected: isSelected)
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview {
    VStack(spacing: 20) {
        // Card style preview
        Button {
            // Action
        } label: {
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

        // Row style preview
        Button {
            // Action
        } label: {
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

        // Pressable button preview
        Button {
            // Action
        } label: {
            Image(systemName: "play.fill")
                .font(.title)
        }
        .buttonStyle(.pressable)
    }
    .padding()
}
