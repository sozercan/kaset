import SwiftUI

// MARK: - PlayerBarSliderVisuals

enum PlayerBarSliderVisuals {
    static let trackThickness: CGFloat = 4
    static let hitOutset: CGFloat = 8
    static let thumbDefaultDiameter: CGFloat = 10
    static let thumbHoverDiameter: CGFloat = 12
    static let thumbActiveDiameter: CGFloat = 14

    static let thumbAnimation = Animation.spring(response: 0.24, dampingFraction: 0.72)
    static let trackAnimation = Animation.easeInOut(duration: 0.15)

    static func trackColor(colorScheme: ColorScheme, isActive: Bool) -> Color {
        let opacity = isActive ? 0.28 : 0.18
        return colorScheme == .dark ? .white.opacity(opacity) : .black.opacity(opacity)
    }

    static func thumbDiameter(isHovering: Bool, isDragging: Bool) -> CGFloat {
        if isDragging {
            return self.thumbActiveDiameter
        }
        if isHovering {
            return self.thumbHoverDiameter
        }
        return self.thumbDefaultDiameter
    }
}
