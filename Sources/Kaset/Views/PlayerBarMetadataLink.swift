import SwiftUI

// MARK: - PlayerBarMetadataButton

struct PlayerBarMetadataButton: View {
    let text: String
    let isEnabled: Bool
    var isLoading = false
    var accessibilityIdentifier: String?
    let action: () -> Void

    var body: some View {
        if self.isEnabled {
            PlayerBarMetadataLinkLabel(text: self.text, isLoading: self.isLoading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture(perform: self.action)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    self.action()
                }
                .playerBarMetadataAccessibilityIdentifier(self.accessibilityIdentifier)
        } else {
            PlayerBarMetadataLinkLabel(text: self.text, isLoading: false)
                .playerBarMetadataAccessibilityIdentifier(self.accessibilityIdentifier)
        }
    }
}

// MARK: - PlayerBarMetadataLinkLabel

private struct PlayerBarMetadataLinkLabel: View {
    let text: String
    var isLoading = false

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(self.text)
                .font(.system(size: 12))
                .lineLimit(1)

            if self.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.42)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(height: 12, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.trailing, 14)
        .contentShape(.rect)
        .padding(.vertical, -6)
        .padding(.trailing, -14)
        .foregroundStyle(self.isHovering ? .primary : .secondary)
        .animation(.easeInOut(duration: 0.15), value: self.isHovering)
        .animation(.easeInOut(duration: 0.12), value: self.isLoading)
        .onHover { hovering in
            self.isHovering = hovering
        }
    }
}

// MARK: - Accessibility Helpers

private extension View {
    @ViewBuilder
    func playerBarMetadataAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            self.accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
