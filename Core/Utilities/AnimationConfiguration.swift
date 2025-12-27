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




