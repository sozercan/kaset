import SwiftUI

// MARK: - QueueView

/// Right sidebar panel displaying the playback queue.
@available(macOS 26.0, *)
struct QueueView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(\.showCommandBar) private var showCommandBar

    /// Namespace for glass effect morphing.
    @Namespace private var queueNamespace

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 0) {
                // Header
                self.headerView

                Divider()
                    .opacity(0.3)

                // Content
                self.contentView
            }
            .frame(width: 280)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
            .glassEffectID("queuePanel", in: self.queueNamespace)
        }
        .glassEffectTransition(.materialize)
        .accessibilityIdentifier(AccessibilityID.Queue.container)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Up Next")
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            // Clear queue button (only show if there are items beyond the current track)
            if self.playerService.queue.count > 1 {
                Button {
                    self.playerService.clearQueue()
                } label: {
                    Text("Clear")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.Queue.clearButton)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        if self.playerService.queue.isEmpty {
            self.emptyQueueView
        } else {
            self.queueListView
        }
    }

    private var emptyQueueView: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text("No Queue")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Play songs from a playlist or album to build your queue.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(AccessibilityID.Queue.emptyState)
    }

    private var queueListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(self.playerService.queue.enumerated()), id: \.element.videoId) { index, song in
                    QueueRowView(
                        song: song,
                        isCurrentTrack: index == self.playerService.currentIndex,
                        index: index,
                        favoritesManager: self.favoritesManager,
                        playerService: self.playerService,
                        onRemove: {
                            self.playerService.removeFromQueue(videoIds: [song.videoId])
                        },
                        onTap: {
                            Task {
                                await self.playerService.playFromQueue(at: index)
                            }
                        }
                    )
                    .accessibilityIdentifier(AccessibilityID.Queue.row(index: index))
                }
            }
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier(AccessibilityID.Queue.scrollView)
    }
}

// MARK: - QueueRowView

@available(macOS 26.0, *)
private struct QueueRowView: View {
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
                CachedAsyncImage(url: self.song.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .overlay {
                            CassetteIcon(size: 16)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                // Track info
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.song.title)
                        .font(.system(size: 13, weight: self.isCurrentTrack ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(self.isCurrentTrack ? .red : .primary)

                    Text(self.song.artistsDisplay.isEmpty ? "Unknown Artist" : self.song.artistsDisplay)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }

                Spacer()

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

@available(macOS 26.0, *)
#Preview("Queue View") {
    let playerService = PlayerService()
    QueueView()
        .environment(playerService)
        .environment(FavoritesManager.shared)
        .frame(height: 600)
}

@available(macOS 26.0, *)
#Preview("Queue View with Items") {
    let playerService = PlayerService()
    // Note: In real use, queue would be populated via playQueue()
    QueueView()
        .environment(playerService)
        .environment(FavoritesManager.shared)
        .frame(height: 600)
}
