import AppKit

@MainActor
enum HapticService {
    enum FeedbackType {
        case playbackAction
        case toggle
        case sliderBoundary
        case navigation
        case success
        case error

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

    private static var isEnabled: Bool {
        guard SettingsManager.shared.hapticFeedbackEnabled else {
            return false
        }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return false
        }

        return true
    }

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

    static func playback() {
        self.perform(.playbackAction)
    }

    static func toggle() {
        self.perform(.toggle)
    }

    static func sliderBoundary() {
        self.perform(.sliderBoundary)
    }

    static func navigation() {
        self.perform(.navigation)
    }

    static func success() {
        self.perform(.success)
    }

    static func error() {
        self.perform(.error)
    }
}
