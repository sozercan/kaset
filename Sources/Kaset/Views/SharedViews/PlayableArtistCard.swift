import SwiftUI

// MARK: - PlayableArtistCard

/// Wraps a card whose thumbnail sits at the top of its layout so that hovering
/// reveals a play button that starts playback directly, while the surrounding
/// `NavigationLink` still opens the item. `playAction` is nil for items that
/// aren't directly playable (e.g. mood-category tiles or artists).
///
/// `thumbnailSize` is the edge length of the square thumbnail, used to center
/// the play button vertically over it.
struct PlayableArtistCard<Content: View>: View {
    let playAction: (() -> Void)?
    let thumbnailSize: CGFloat
    let content: Content

    private static var playButtonSize: CGSize {
        CGSize(width: 48, height: 48)
    }

    @State private var isHovering = false

    init(playAction: (() -> Void)?, thumbnailSize: CGFloat, @ViewBuilder content: () -> Content) {
        self.playAction = playAction
        self.thumbnailSize = thumbnailSize
        self.content = content()
    }

    var body: some View {
        self.content
            .overlay(alignment: .top) {
                if let playAction = self.playAction, self.isHovering {
                    Button(action: playAction) {
                        LiquidGlassPlayIcon(size: Self.playButtonSize, interactive: true)
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, (self.thumbnailSize - Self.playButtonSize.height) / 2)
                    .transition(.opacity)
                }
            }
            .animation(AppAnimation.quick, value: self.isHovering)
            .onHover { hovering in
                self.isHovering = hovering
            }
    }
}
