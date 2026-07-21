import SwiftUI

// MARK: - QueueView

/// Right sidebar panel displaying the playback queue.
struct QueueView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(\.showCommandBar) private var showCommandBar

    /// Namespace for glass effect morphing.
    @Namespace private var queueNamespace

    var body: some View {
        CompatGlassContainer(spacing: 0) {
            VStack(spacing: 0) {
                // Header
                self.headerView

                Divider()
                    .opacity(0.3)

                // Content
                self.contentView
            }
            .frame(width: 280)
            .compatGlass(interactive: true, in: .rect(cornerRadius: 20))
            .compatGlassID("queuePanel", in: self.queueNamespace)
        }
        .compatGlassTransition(.materialize)
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

            Button {
                self.playerService.toggleQueueDisplayMode()
            } label: {
                Label("Edit", systemImage: "square.and.pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Open queue in side panel"))
            .accessibilityLabel(String(localized: "Open queue in side panel"))
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
                ForEach(Array(self.playerService.queueEntries.enumerated()), id: \.element.id) { index, entry in
                    QueueRowView(
                        song: entry.song,
                        isCurrentTrack: index == self.playerService.currentIndex,
                        index: index,
                        favoritesManager: self.favoritesManager,
                        playerService: self.playerService,
                        onRemove: {
                            self.playerService.removeFromQueue(entryIDs: Set([entry.id]))
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

#Preview("Queue View") {
    let playerService = PlayerService()
    QueueView()
        .environment(playerService)
        .environment(FavoritesManager.shared)
        .frame(height: 600)
}

#Preview("Queue View with Items") {
    let playerService = PlayerService()
    // Note: In real use, queue would be populated via playQueue()
    QueueView()
        .environment(playerService)
        .environment(FavoritesManager.shared)
        .frame(height: 600)
}
