// AccountRowView.swift
// Kaset
//
// A single account row component for the account switcher.

import SwiftUI

/// A single account row component displaying account info.
///
/// Shows the account avatar, name, handle, type badge, and selection state.
@available(macOS 26.0, *)
struct AccountRowView: View {
    let account: UserAccount
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: self.onSelect) {
            HStack(spacing: 12) {
                // Avatar
                self.avatarView

                // Account info
                VStack(alignment: .leading, spacing: 2) {
                    // Name
                    Text(self.account.name)
                        .font(.body)
                        .fontWeight(self.isSelected ? .semibold : .regular)
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    // Handle (if available)
                    if let handle = account.handle {
                        Text(handle)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Type badge
                self.typeBadge

                // Selection checkmark
                if self.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)
                        .accessibilityLabel("Selected")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(self.rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.isHovering = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.accessibilityLabel)
        .accessibilityAddTraits(self.isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Double-tap to switch to this account")
    }

    // MARK: - Avatar View

    private var avatarView: some View {
        Group {
            if let thumbnailURL = account.thumbnailURL {
                CachedAsyncImage(url: thumbnailURL, targetSize: CGSize(width: 80, height: 80)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    self.avatarPlaceholder
                }
            } else {
                self.avatarPlaceholder
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(.circle)
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
    }

    // MARK: - Type Badge

    private var typeBadge: some View {
        Text(self.account.typeLabel)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(self.account.isPrimary ? .blue : .orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(self.account.isPrimary ? Color.blue.opacity(0.15) : Color.orange.opacity(0.15))
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    }
            }
    }

    // MARK: - Background

    @ViewBuilder
    private var rowBackground: some View {
        if self.isSelected || self.isHovering {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(self.isSelected ? 0.16 : 0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.white.opacity(self.isSelected ? 0.22 : 0.14), lineWidth: 1)
                }
        } else {
            Color.clear
        }
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        var label = self.account.name

        if let handle = account.handle {
            label += ", \(handle)"
        }

        label += ", \(self.account.typeLabel) account"

        if self.isSelected {
            label += ", currently selected"
        }

        return label
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview("Primary Account - Selected") {
    let account = UserAccount(
        id: "primary",
        name: "John Doe",
        handle: "@johndoe",
        brandId: nil,
        thumbnailURL: URL(string: "https://example.com/avatar.jpg"),
        isSelected: true
    )

    AccountRowView(
        account: account,
        isSelected: true,
        onSelect: {}
    )
    .frame(width: 280)
    .padding()
}

@available(macOS 26.0, *)
#Preview("Brand Account - Not Selected") {
    let account = UserAccount(
        id: "brand123",
        name: "Music Channel",
        handle: "@musicchannel",
        brandId: "brand123",
        thumbnailURL: nil,
        isSelected: false
    )

    AccountRowView(
        account: account,
        isSelected: false,
        onSelect: {}
    )
    .frame(width: 280)
    .padding()
}

@available(macOS 26.0, *)
#Preview("Account Without Handle") {
    let account = UserAccount(
        id: "nohandle",
        name: "No Handle User",
        handle: nil,
        brandId: nil,
        thumbnailURL: nil,
        isSelected: false
    )

    AccountRowView(
        account: account,
        isSelected: false,
        onSelect: {}
    )
    .frame(width: 280)
    .padding()
}
