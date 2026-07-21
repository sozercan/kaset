import SwiftUI

// MARK: - QueueRowView

/// A single row in a queue list, shared by the queue sidebar panel and the expanded player.
struct QueueRowView: View {
    let song: Song
    let isCurrentTrack: Bool
    let index: Int
    let favoritesManager: FavoritesManager
    let playerService: PlayerService
    let onRemove: () -> Void
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: self.onTap) {
            HStack(spacing: 12) {
                // Now Playing indicator or track number
                self.leadingIndicator
                    .frame(width: 24)

                // Thumbnail
                SongThumbnailView(song: self.song, size: 40, cornerRadius: 4)

                // Track info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(self.song.title)
                            .font(.system(size: 13, weight: self.isCurrentTrack ? .semibold : .regular))
                            .lineLimit(1)
                            .foregroundStyle(self.isCurrentTrack ? .red : .primary)
                        if self.song.isExplicit == true {
                            ExplicitBadge()
                        }
                    }

                    Text(self.song.artistsDisplay.isEmpty ? String(localized: "Unknown Artist") : self.song.artistsDisplay)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Favorite toggle
                LikeButton(song: self.song, isRowHovered: self.isHovering)

                // Duration
                if let duration = song.duration {
                    Text(self.formatDuration(duration))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(self.backgroundColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.isHovering = hovering
        }
        .contextMenu {
            FavoritesContextMenu.menuItem(for: self.song, manager: self.favoritesManager)

            Divider()

            StartRadioContextMenu.menuItem(for: self.song, playerService: self.playerService)

            Divider()

            ShareContextMenu.menuItem(for: self.song)

            if !self.isCurrentTrack {
                Button(role: .destructive) {
                    self.onRemove()
                } label: {
                    Label("Remove from Queue", systemImage: "minus.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        if self.isCurrentTrack {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(self.playerService.isPlaying ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                .symbolEffect(
                    .variableColor.iterative,
                    options: .repeating,
                    isActive: self.playerService.isPlaying
                )
        } else {
            Text("\(self.index + 1)")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    private var backgroundColor: Color {
        if self.isCurrentTrack {
            return Color.red.opacity(0.1)
        } else if self.isHovering {
            return Color.primary.opacity(0.05)
        }
        return .clear
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
