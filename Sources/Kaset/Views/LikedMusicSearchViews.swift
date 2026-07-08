import SwiftUI

// MARK: - LikedMusicSearchFieldStyle

enum LikedMusicSearchFieldStyle {
    case liquidGlass
    case fallback
}

// MARK: - LikedMusicSearchField

struct LikedMusicSearchField: View {
    let text: Binding<String>
    let isFocused: FocusState<Bool>.Binding
    let isActive: Bool
    let style: LikedMusicSearchFieldStyle
    let onClear: () -> Void

    var body: some View {
        switch self.style {
        case .liquidGlass:
            self.content
                .padding(10)
                .compatGlass(in: .capsule)
        case .fallback:
            self.content
                .padding(10)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(String(localized: "Search liked songs..."), text: self.text)
                .textFieldStyle(.plain)
                .focused(self.isFocused)
                .accessibilityIdentifier(AccessibilityID.LikedMusic.searchField)

            if self.isActive {
                Button {
                    self.onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear liked music search"))
                .accessibilityIdentifier(AccessibilityID.LikedMusic.clearSearchButton)
            }
        }
    }
}

// MARK: - LikedMusicSearchEmptyState

struct LikedMusicSearchEmptyState: View {
    let hasMore: Bool
    var iconSize: CGFloat = 36

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: self.iconSize))
                .foregroundStyle(.tertiary)

            Text(self.hasMore ? String(localized: "Still searching liked songs...") : String(localized: "No liked songs found"))
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(
                self.hasMore
                    ? String(localized: "More liked songs are loading and results will appear here as they match.")
                    : String(localized: "Try a different song, artist, or album name.")
            )
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityIdentifier(AccessibilityID.LikedMusic.searchEmptyState)
    }
}
