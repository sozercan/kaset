import SwiftUI

// MARK: - AppAnimation

/// Centralized animation constants for consistent motion design throughout the app.
/// All animations respect the system's "Reduce Motion" accessibility setting.
enum AppAnimation {
    // MARK: - Duration Constants

    /// Quick interactions like button presses (0.15s)
    static let quick = Animation.easeOut(duration: 0.15)

    /// Standard UI transitions (0.25s)
    static let standard = Animation.easeInOut(duration: 0.25)

    /// Smooth, noticeable transitions (0.35s)
    static let smooth = Animation.easeInOut(duration: 0.35)

    /// Decorative, ambient animations (0.5s)
    static let ambient = Animation.easeInOut(duration: 0.5)

    // MARK: - Spring Animations

    /// Responsive spring for interactive elements
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.7)

    /// Bouncy spring for playful feedback
    static let bouncy = Animation.spring(response: 0.4, dampingFraction: 0.6)

    /// Snappy spring for quick snaps
    static let snappy = Animation.spring(response: 0.25, dampingFraction: 0.8)

    // MARK: - Stagger Delays

    /// Base delay for staggered list animations
    static let staggerDelay: Double = 0.05

    /// Maximum stagger delay to prevent long waits
    static let maxStaggerDelay: Double = 0.5

    /// Calculate stagger delay for a given index
    static func stagger(for index: Int, base: Double = staggerDelay) -> Double {
        min(Double(index) * base, self.maxStaggerDelay)
    }
}

// MARK: - ReducedMotionKey

/// Environment key for checking reduced motion preference.
private struct ReducedMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the system's "Reduce Motion" setting is enabled.
    var prefersReducedMotion: Bool {
        get { self[ReducedMotionKey.self] }
        set { self[ReducedMotionKey.self] = newValue }
    }
}

// MARK: - Conditional Animation Modifier

extension View {
    /// Applies an animation only if reduced motion is not enabled.
    /// Falls back to instant transitions when reduced motion is preferred.
    /// - Parameters:
    ///   - animation: The animation to apply when motion is allowed.
    ///   - value: The value to animate.
    /// - Returns: A view with conditional animation.
    func animateIfAllowed(
        _ animation: Animation,
        value: some Equatable
    ) -> some View {
        modifier(ConditionalAnimationModifier(animation: animation, value: value))
    }

    /// Wraps content in withAnimation only if reduced motion is not enabled.
    func withAnimationIfAllowed<Result>(
        _ animation: Animation = AppAnimation.standard,
        _ body: () throws -> Result
    ) rethrows -> Result {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try body()
        } else {
            try withAnimation(animation, body)
        }
    }
}

// MARK: - ConditionalAnimationModifier

/// Modifier that conditionally applies animation based on accessibility settings.
private struct ConditionalAnimationModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            content
        } else {
            content.animation(self.animation, value: self.value)
        }
    }
}

// MARK: - HapticFeedback

enum HapticFeedback {
    case selection
    case impact
    case success
    case error

    /// Perform haptic feedback if available.
    /// Note: macOS haptic feedback is limited compared to iOS.
    func perform() {
        // macOS doesn't have the same haptic API as iOS,
        // but we can use NSHapticFeedbackManager for supported devices
        switch self {
        case .selection:
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        case .impact:
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        case .success:
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        case .error:
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
    }
}
