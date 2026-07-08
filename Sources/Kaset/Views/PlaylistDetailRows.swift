import SwiftUI

// MARK: - PlaylistTrackRow

@available(macOS 26.0, *)
struct PlaylistTrackRow<Menu: View>: View {
    let track: Song
    let index: Int
    let isAlbum: Bool
    let subtitle: String?
    let allowsLikeActions: Bool
    let onPlay: () -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var isHovered: Bool = false
    @Environment(PlayerService.self) private var playerService

    var body: some View {
        let isCurrent = self.playerService.currentTrack?.videoId == self.track.videoId

        Button(action: self.onPlay) {
            HStack(spacing: 12) {
                Group {
                    if isCurrent {
                        NowPlayingIndicator(isPlaying: self.playerService.isPlaying, size: 14)
                    } else {
                        Text("\(self.index + 1)")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 28, alignment: .trailing)

                if !self.isAlbum {
                    CachedAsyncImage(url: self.track.thumbnailURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(.quaternary)
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(.rect(cornerRadius: 4))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(self.track.title)
                            .font(.system(size: 14))
                            .foregroundStyle(isCurrent ? .red : .primary)
                            .lineLimit(1)
                        if self.track.isExplicit == true {
                            ExplicitBadge()
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                LikeButton(song: self.track, isRowHovered: self.isHovered, allowsActions: self.allowsLikeActions)

                Text(self.track.durationDisplay)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 45, alignment: .trailing)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .opacity(self.track.isPlayable ? 1 : 0.5)
        }
        .buttonStyle(.interactiveRow(cornerRadius: 6))
        .disabled(!self.track.isPlayable)
        .onHover { hovering in self.isHovered = hovering }
        .contextMenu { self.menu() }
    }
}

// MARK: - HoverUnderlineNavigationLink

struct HoverUnderlineNavigationLink<Value: Hashable>: View {
    let value: Value
    let title: String

    @State private var isHovering = false

    var body: some View {
        NavigationLink(value: self.value) {
            Text(self.title)
                .font(.subheadline)
                .underline(self.isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.isHovering = hovering
        }
    }
}

// MARK: - HeaderArtistLinkLabel

struct HeaderArtistLinkLabel: View {
    let name: String

    @State private var isHovering = false

    var body: some View {
        Text(self.name)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(self.isHovering ? .primary : .secondary)
            .animation(.easeInOut(duration: 0.15), value: self.isHovering)
            .onHover { hovering in
                self.isHovering = hovering
            }
    }
}
