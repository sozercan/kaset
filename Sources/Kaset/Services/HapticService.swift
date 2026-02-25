import AppKit

/// Centralized service for haptic feedback on macOS.
/// Uses the Force Touch trackpad via NSHapticFeedbackManager.
@MainActor
enum HapticService {
    /// Types of haptic feedback mapped to user actions.
    enum FeedbackType {
        /// Playback actions like play, pause, skip.
        case playbackAction
        /// Toggle actions like shuffle, repeat, like/dislike.
        case toggle
        /// Slider boundaries (volume/seek at limits).
        case sliderBoundary
        /// Navigation selection in sidebar.
        case navigation
        /// Successful action completion (add to library).
        case success
        /// Action failure.
        case error

        /// Maps the feedback type to NSHapticFeedbackManager pattern.
        fileprivate var pattern: NSHapticFeedbackManager.FeedbackPattern {
            switch self {
            case .playbackAction:
                .generic
            case .toggle:
                .alignment
            case .sliderBoundary:
                .levelChange
            case .navigation:
                .alignment
            case .success:
                .generic
            case .error:
                .generic
            }
        }
    }

    /// Whether haptic feedback is currently enabled.
    /// Checks both user preference and system accessibility settings.
    private static var isEnabled: Bool {
        // Respect user preference
        guard SettingsManager.shared.hapticFeedbackEnabled else {
            return false
        }

        // Respect system accessibility setting for reduced motion
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return false
        }

        return true
    }

    /// Performs haptic feedback of the specified type.
    /// - Parameter type: The type of feedback to perform.
    static func perform(_ type: FeedbackType) {
        guard self.isEnabled else {
            DiagnosticsLogger.haptic.debug("Haptic feedback disabled, skipping \(String(describing: type))")
            return
        }

        DiagnosticsLogger.haptic.debug("Performing haptic feedback: \(String(describing: type))")

        NSHapticFeedbackManager.defaultPerformer.perform(
            type.pattern,
            performanceTime: .now
        )
    }

    /// Performs haptic feedback for a playback action (play, pause, skip).
    static func playback() {
        self.perform(.playbackAction)
    }

    /// Performs haptic feedback for a toggle action (shuffle, repeat, like).
    static func toggle() {
        self.perform(.toggle)
    }

    /// Performs haptic feedback when a slider reaches its boundary (0% or 100%).
    static func sliderBoundary() {
        self.perform(.sliderBoundary)
    }

    /// Performs haptic feedback for navigation selection.
    static func navigation() {
        self.perform(.navigation)
    }

    /// Performs haptic feedback for successful action completion.
    static func success() {
        self.perform(.success)
    }

    /// Performs haptic feedback for action failure.
    static func error() {
        self.perform(.error)
    }
}
