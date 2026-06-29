import SwiftUI

// MARK: - PlayerBarArtworkView

struct PlayerBarArtworkView<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    var glowSources: [URL] = []
    var glowIdentity: String?
    var glowTargetSize: CGSize?
    var showsHoverOverlay = true
    var isLoading = false
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        ZStack {
            PlayerBarArtworkGlow(
                sources: self.glowSources,
                identity: self.glowIdentity,
                targetSize: self.glowTargetSize,
                width: self.width,
                height: self.height,
                cornerRadius: self.cornerRadius
            )

            ZStack {
                self.content()
                    .frame(width: self.width, height: self.height)
                    .blur(radius: self.showsActiveOverlay ? 3 : 0)

                if self.showsActiveOverlay {
                    RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                        .fill(self.overlayFill)

                    if self.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.55)
                    } else {
                        Image(systemName: "music.pages.fill")
                            .font(.system(size: self.iconSize, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .frame(width: self.width, height: self.height)
            .clipShape(.rect(cornerRadius: self.cornerRadius, style: .continuous))
        }
        .frame(width: self.width, height: self.height)
        .contentShape(.rect(cornerRadius: self.cornerRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.16), value: self.showsActiveOverlay)
        .onHover { hovering in
            self.isHovering = hovering
        }
    }

    private var showsActiveOverlay: Bool {
        self.showsHoverOverlay && (self.isHovering || self.isLoading)
    }

    private var overlayFill: Color {
        self.colorScheme == .dark ? .white.opacity(0.14) : .white.opacity(0.42)
    }

    private var iconSize: CGFloat {
        min(self.width, self.height) >= 32 ? 14 : 13
    }
}
