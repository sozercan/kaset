import SwiftUI

// MARK: - PlayerBarIconMenu

struct PlayerBarIconMenu<MenuContent: View, Icon: View>: View {
    var isSelected = false
    var accessibilityID: String?
    var accessibilityLabel: String?
    @ViewBuilder var menuContent: () -> MenuContent
    @ViewBuilder var icon: () -> Icon

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        ZStack {
            self.icon()
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(self.backgroundColor)
                }
                .accessibilityHidden(true)

            Menu {
                self.menuContent()
            } label: {
                Label {
                    Text(self.accessibilityLabel ?? "")
                } icon: {
                    // A borderless menu is an AppKit pop-up button sized to its label
                    // image. Arbitrary views such as a clear `Color` are not rendered
                    // into that image, which collapses the button to a few points in
                    // the middle of the 28pt slot. A transparent 28pt image keeps the
                    // whole slot clickable, matching `PlayerBarIconButton`.
                    Image(size: CGSize(width: 28, height: 28)) { _ in }
                }
                .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .playerBarMenuAccessibilityIdentifier(self.accessibilityID)
            .playerBarMenuAccessibilityLabel(self.accessibilityLabel)
        }
        .frame(width: 28, height: 28)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(self.isEnabled ? 1 : 0.38)
        .onHover { hovering in
            withAnimation(AppAnimation.quick) {
                self.isHovering = hovering
            }
        }
    }

    private var backgroundColor: Color {
        let baseColor: Color = self.colorScheme == .dark ? .white : .black
        if self.isHovering, self.isEnabled {
            return baseColor.opacity(0.08)
        }
        if self.isSelected {
            return baseColor.opacity(0.06)
        }
        return .clear
    }
}

// MARK: - Accessibility Helpers

private extension View {
    @ViewBuilder
    func playerBarMenuAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            self.accessibilityIdentifier(identifier)
        } else {
            self
        }
    }

    @ViewBuilder
    func playerBarMenuAccessibilityLabel(_ label: String?) -> some View {
        if let label {
            self.accessibilityLabel(label)
        } else {
            self
        }
    }
}
