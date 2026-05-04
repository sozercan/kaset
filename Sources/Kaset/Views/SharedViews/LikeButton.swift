import SwiftUI

// MARK: - LikeButton

/// One-click thumbs-up toggle that mirrors YouTube Music's per-track like state.
///
/// Visibility rules:
/// - Filled red `hand.thumbsup.fill` is always visible when the song is liked.
/// - Outline `hand.thumbsup` shows only when `isRowHovered` is true.
///
/// The button delegates to `SongActionsHelper.likeSong/unlikeSong` — the same
/// path used by `LikeDislikeContextMenu`. Tap events do not propagate to the
/// surrounding row button (`.buttonStyle(.borderless)` plus `.contentShape`
/// on a tight frame keeps the hit area local).
@available(macOS 26.0, *)
struct LikeButton: View {
    let song: Song
    let isRowHovered: Bool
    @Environment(SongLikeStatusManager.self) private var likeStatusManager

    var body: some View {
        let isLiked = self.likeStatusManager.isLiked(self.song)
        Button {
            HapticService.success()
            if isLiked {
                SongActionsHelper.unlikeSong(self.song, likeStatusManager: self.likeStatusManager)
            } else {
                SongActionsHelper.likeSong(self.song, likeStatusManager: self.likeStatusManager)
            }
        } label: {
            Image(systemName: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                .font(.system(size: 13))
                .foregroundStyle(isLiked ? .red : .secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .opacity(isLiked || self.isRowHovered ? 1 : 0)
        .animation(.easeInOut(duration: 0.12), value: isLiked)
        .animation(.easeInOut(duration: 0.12), value: self.isRowHovered)
        .accessibilityLabel(Text(
            isLiked
                ? String(localized: "Unlike")
                : String(localized: "Like")
        ))
        .help(
            isLiked
                ? String(localized: "Unlike")
                : String(localized: "Like")
        )
    }
}

// MARK: - HoverObservingRow

/// Wraps a row's body and provides per-row hover state via closure.
/// Use to drive `LikeButton.isRowHovered` and any other hover-only chrome.
@available(macOS 26.0, *)
struct HoverObservingRow<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var isHovered: Bool = false

    var body: some View {
        self.content(self.isHovered)
            .onHover { hovering in self.isHovered = hovering }
    }
}
