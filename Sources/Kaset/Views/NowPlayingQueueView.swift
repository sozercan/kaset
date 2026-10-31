import SwiftUI

// MARK: - NowPlayingQueueView

/// Up Next list for the full screen Now Playing view: borderless rows over the blurred
/// artwork backdrop, played tracks dimmed above the current one, which is scrolled to the top.
struct NowPlayingQueueView: View {
    @Environment(PlayerService.self) private var playerService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            self.header

            if self.playerService.queue.isEmpty {
                self.emptyState
            } else {
                self.list
            }
        }
        .frame(maxWidth: 520, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(String(localized: "Up Next"))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            if self.playerService.queue.count > 1 {
                Button {
                    self.playerService.clearQueue()
                } label: {
                    Text(String(localized: "Clear"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.12), in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(String(localized: "No Queue"))
                .font(.headline)
                .foregroundStyle(.white.opacity(0.8))

            Text(String(localized: "Play songs from a playlist or album to build your queue."))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        let currentIndex = self.playerService.activePlaybackQueueIndex

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(self.playerService.queueEntries.enumerated()), id: \.element.id) { index, entry in
                        NowPlayingQueueRow(
                            entry: entry,
                            position: Self.position(of: index, currentIndex: currentIndex),
                            isPlaying: self.playerService.isPlaying,
                            onPlay: { self.play(entry) },
                            onRemove: { self.playerService.removeFromQueue(entryIDs: [entry.id]) }
                        )
                        .id(entry.id)
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .mask {
                // Fade rows out under the bottom edge instead of clipping them.
                LinearGradient(
                    stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .onChange(of: self.currentEntryID, initial: true) { _, entryID in
                guard let entryID else { return }
                withAnimation(AppAnimation.standard) {
                    proxy.scrollTo(entryID, anchor: .top)
                }
            }
        }
    }

    private var currentEntryID: UUID? {
        guard let index = self.playerService.activePlaybackQueueIndex,
              self.playerService.queueEntries.indices.contains(index)
        else { return nil }
        return self.playerService.queueEntries[index].id
    }

    static func position(of index: Int, currentIndex: Int?) -> NowPlayingQueueRow.Position {
        guard let currentIndex else { return .upcoming }
        if index < currentIndex {
            return .played
        }
        return index == currentIndex ? .current : .upcoming
    }

    private func play(_ entry: QueueEntry) {
        let reservation = self.playerService.reserveMusicPlaybackIntent()
        Task { @MainActor in
            guard let intent = self.playerService.claimMusicPlaybackIntent(
                reservation,
                queueEntryID: entry.id
            ) else { return }
            await self.playerService.playFromQueue(entryID: entry.id, intent: intent)
        }
    }
}

// MARK: - NowPlayingQueueRow

struct NowPlayingQueueRow: View {
    enum Position {
        case played
        case current
        case upcoming
    }

    let entry: QueueEntry
    let position: Position
    let isPlaying: Bool
    let onPlay: () -> Void
    let onRemove: () -> Void

    @Environment(PlayerService.self) private var playerService
    @State private var isHovering = false

    var body: some View {
        Button(action: self.onPlay) {
            HStack(spacing: 12) {
                self.artwork

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(self.entry.song.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if self.entry.song.isExplicit == true {
                            ExplicitBadge()
                        }

                        if self.entry.source == .suggested {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(PackageResourceLookup.brandAccent)
                                .accessibilityLabel(String(localized: "Suggested"))
                        }
                    }

                    Text(self.artistName)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let duration = self.entry.song.duration {
                    Text(PlayerBarSeekController.formatTime(duration))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(self.background, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .opacity(self.position == .played && !self.isHovering ? 0.45 : 1)
        .onHover { self.isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: self.isHovering)
        .contextMenu {
            SongContextMenu(
                song: self.entry.song,
                client: self.playerService.ytMusicClient,
                play: self.position == .current ? nil : self.onPlay,
                showsGoToArtist: false,
                showsGoToAlbum: false
            )

            if self.position != .current {
                Divider()

                Button(role: .destructive, action: self.onRemove) {
                    Label(String(localized: "Remove from Queue"), systemImage: "minus.circle")
                }
            }
        }
        .accessibilityAddTraits(self.position == .current ? .isSelected : [])
    }

    private var artwork: some View {
        SongThumbnailView(song: self.entry.song, size: 40, cornerRadius: 5)
            .overlay {
                if self.position == .current {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.black.opacity(0.45))
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: self.isPlaying)
                }
            }
    }

    private var background: Color {
        if self.position == .current {
            return .white.opacity(0.14)
        }
        return self.isHovering ? .white.opacity(0.08) : .clear
    }

    private var artistName: String {
        self.entry.song.artistsDisplay.isEmpty ? String(localized: "Unknown Artist") : self.entry.song.artistsDisplay
    }
}
