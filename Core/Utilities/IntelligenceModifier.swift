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

    /// Access to the Foundation Models service.
    @State private var isAvailable = FoundationModelsService.shared.isAvailable

    func body(content: Content) -> some View {
        if self.hideWhenUnavailable, !self.isAvailable {
            EmptyView()
        } else {
            content
                .disabled(!self.isAvailable)
                .opacity(self.isAvailable ? 1.0 : 0.5)
                .help(self.isAvailable ? "" : self.unavailableMessage)
                .onReceive(NotificationCenter.default.publisher(for: .intelligenceAvailabilityChanged)) { _ in
                    self.isAvailable = FoundationModelsService.shared.isAvailable
                }
        }
    }
}

// MARK: - View Extension

@available(macOS 26.0, *)
extension View {
    /// Marks this view as requiring Apple Intelligence.
    /// When AI is unavailable, the view will be dimmed and disabled with a tooltip.
    /// - Parameters:
    ///   - hideWhenUnavailable: If true, completely hides the view instead of dimming.
    ///   - message: Custom tooltip message shown when hovering over disabled content.
    /// - Returns: A modified view that responds to AI availability.
    func requiresIntelligence(
        hideWhenUnavailable: Bool = false,
        message: String = "Requires Apple Intelligence"
    ) -> some View {
        modifier(RequiresIntelligenceModifier(
            hideWhenUnavailable: hideWhenUnavailable,
            unavailableMessage: message
        ))
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted when Apple Intelligence availability changes.
    static let intelligenceAvailabilityChanged = Notification.Name("intelligenceAvailabilityChanged")
}
