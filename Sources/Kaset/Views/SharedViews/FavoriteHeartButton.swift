import SwiftUI

// MARK: - FavoriteHeartButton

/// One-click heart toggle for adding/removing a song from local Favorites.
///
/// Visibility rules:
/// - Filled red `heart.fill` is always visible when the song is favorited.
/// - Outline `heart` shows only when `isRowHovered` is true.
///
/// The button taps `FavoritesManager.toggle(song:)` — the same code path used
/// by `FavoritesContextMenu`. Tap events do not propagate to the surrounding
/// row button (`.buttonStyle(.borderless)` plus `.contentShape` on a tight
/// frame keeps the hit area local).
@available(macOS 26.0, *)
struct FavoriteHeartButton: View {
    let song: Song
    let isRowHovered: Bool
    @Environment(FavoritesManager.self) private var favoritesManager

    var body: some View {
        let isFavorited = self.favoritesManager.isPinned(song: self.song)
        Button {
            HapticService.success()
            self.favoritesManager.toggle(song: self.song)
        } label: {
            Image(systemName: isFavorited ? "heart.fill" : "heart")
                .font(.system(size: 13))
                .foregroundStyle(isFavorited ? .red : .secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .opacity(isFavorited || self.isRowHovered ? 1 : 0)
        .animation(.easeInOut(duration: 0.12), value: isFavorited)
        .animation(.easeInOut(duration: 0.12), value: self.isRowHovered)
        .accessibilityLabel(Text(
            isFavorited
                ? String(localized: "Remove from Favorites")
                : String(localized: "Add to Favorites")
        ))
        .help(
            isFavorited
                ? String(localized: "Remove from Favorites")
                : String(localized: "Add to Favorites")
        )
    }
}

// MARK: - HoverObservingRow

/// Wraps a row's body and provides per-row hover state via closure.
/// Use to drive `FavoriteHeartButton.isRowHovered` and any other hover-only chrome.
@available(macOS 26.0, *)
struct HoverObservingRow<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var isHovered: Bool = false

    var body: some View {
        self.content(self.isHovered)
            .onHover { hovering in self.isHovered = hovering }
    }
}
