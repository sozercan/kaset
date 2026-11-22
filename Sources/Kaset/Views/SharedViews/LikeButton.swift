import SwiftUI

struct LikeButton: View {
    let song: Song
    let isRowHovered: Bool
    var allowsActions = true
    var isNestedInButton = true
    @Environment(SongLikeStatusManager.self) private var likeStatusManager

    var body: some View {
        let isLiked = self.allowsActions && self.likeStatusManager.isLiked(self.song)
        if self.allowsActions {
            Button {
                guard self.allowsActions else { return }
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
            .modifier(LikeButtonStyleModifier(isNestedInButton: self.isNestedInButton))
            .disabled(!self.allowsActions)
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
        } else {
            Color.clear
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        }
    }
}

private struct LikeButtonStyleModifier: ViewModifier {
    let isNestedInButton: Bool

    func body(content: Content) -> some View {
        if self.isNestedInButton {
            content.buttonStyle(.borderless)
        } else {
            content.buttonStyle(.plain)
        }
    }
}

struct HoverObservingRow<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var isHovered: Bool = false

    var body: some View {
        self.content(self.isHovered)
            .onHover { hovering in self.isHovered = hovering }
    }
}
