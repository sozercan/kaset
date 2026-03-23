import SwiftUI

// MARK: - RequiresIntelligenceModifier

/// A view modifier that conditionally shows content based on Apple Intelligence availability.
/// Use `.requiresIntelligence()` on AI-powered buttons and controls.
@available(macOS 26.0, *)
struct RequiresIntelligenceModifier: ViewModifier {
    /// Whether to completely hide the view when unavailable (vs. just dimming it).
    let hideWhenUnavailable: Bool

    /// Custom tooltip message when hovering over disabled content.
    let unavailableMessage: String

    /// Whether to show a sparkle overlay when AI is available and active.
    let showSparkleOverlay: Bool

    /// Reads availability directly from the @Observable singleton.
    /// SwiftUI's Observation system automatically tracks this access
    /// and triggers re-renders when the underlying value changes.
    private var isAvailable: Bool {
        FoundationModelsService.shared.isAvailable
    }

    func body(content: Content) -> some View {
        // Cache availability for consistent reads within this render pass
        let isAvailable = self.isAvailable

        Group {
            if self.hideWhenUnavailable, !isAvailable {
                EmptyView()
            } else {
                content
                    .disabled(!isAvailable)
                    .opacity(isAvailable ? 1.0 : 0.4)
                    .overlay(alignment: .topTrailing) {
                        if self.showSparkleOverlay, isAvailable {
                            Image(systemName: "sparkle")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.purple)
                                .offset(x: 2, y: -2)
                        }
                    }
                    .help(isAvailable ? "" : self.unavailableMessage)
                    .animation(.easeInOut(duration: 0.2), value: isAvailable)
            }
        }
    }
}

// MARK: - View Extension

@available(macOS 26.0, *)
extension View {
    /// Marks this view as requiring Apple Intelligence.
    /// When AI is unavailable, the view will be completely hidden by default.
    /// - Parameters:
    ///   - hideWhenUnavailable: If true (default), completely hides the view instead of dimming.
    ///   - message: Custom tooltip message shown when hovering over disabled content.
    ///   - showSparkle: If true, shows a small sparkle indicator when AI is available.
    /// - Returns: A modified view that responds to AI availability.
    func requiresIntelligence(
        hideWhenUnavailable: Bool = true,
        message: String = "Requires Apple Intelligence",
        showSparkle: Bool = false
    ) -> some View {
        modifier(RequiresIntelligenceModifier(
            hideWhenUnavailable: hideWhenUnavailable,
            unavailableMessage: message,
            showSparkleOverlay: showSparkle
        ))
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted when Apple Intelligence availability changes.
    static let intelligenceAvailabilityChanged = Notification.Name("intelligenceAvailabilityChanged")
}
