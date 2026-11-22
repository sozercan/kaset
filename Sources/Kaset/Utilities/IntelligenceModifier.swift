import SwiftUI

@available(macOS 26.0, *)
struct RequiresIntelligenceModifier: ViewModifier {
    let hideWhenUnavailable: Bool

    let unavailableMessage: String

    let showSparkleOverlay: Bool

    private var isAvailable: Bool {
        FoundationModelsService.shared.isAvailable
    }

    func body(content: Content) -> some View {
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

@available(macOS 26.0, *)
extension View {
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

extension Notification.Name {
    static let intelligenceAvailabilityChanged = Notification.Name("intelligenceAvailabilityChanged")
}
