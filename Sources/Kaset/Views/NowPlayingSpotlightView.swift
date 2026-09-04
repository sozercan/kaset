import SwiftUI

/// Now-Playing Spotlight presentation view featuring a side-by-side layout:
/// large album artwork on the left and track details, artist links, and controls on the right.
struct NowPlayingSpotlightView: View {
    @Environment(\.dismiss) private var dismiss

    let song: Song?
    let isPlaying: Bool
    let progress: TimeInterval
    let duration: TimeInterval
    let volume: Double
    let isMuted: Bool
    let queueSongs: [Song]
    let lyricsText: String?
    let onPlayPause: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onVolumeChange: (Double) -> Void
    let onToggleMute: () -> Void
    let onAirPlay: () -> Void

    @State private var isDrawerVisible = false
    @State private var selectedDrawerTab: SpotlightSideDrawer.Tab = .lyrics

    var body: some View {
        ZStack {
            // Ambient Backdrop Glow
            if let artworkURL = self.song?.thumbnailURL {
                PlayerBarArtworkGlow(
                    sources: [artworkURL],
                    identity: self.song?.id,
                    targetSize: CGSize(width: 800, height: 800),
                    width: 950,
                    height: 950,
                    cornerRadius: 48
                )
                .opacity(0.65)
            }

            VStack(spacing: 0) {
                // Header Bar with Dismiss & AirPlay
                SpotlightHeaderView(
                    onDismiss: { self.dismiss() },
                    onAirPlay: self.onAirPlay
                )

                Spacer(minLength: 20)

                // Side-by-Side Split View
                HStack(alignment: .center, spacing: 48) {
                    // Left Column: Prominent Large Cover Artwork
                    VStack {
                        ZStack {
                            if let artworkURL = self.song?.thumbnailURL {
                                CachedAsyncImage(url: artworkURL) { image in
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    ProgressView()
                                }
                                .frame(width: 380, height: 380)
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                .shadow(color: .black.opacity(0.45), radius: 32, x: 0, y: 16)
                            } else {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .fill(.quaternary)
                                        .frame(width: 380, height: 380)

                                    Image(systemName: "music.note")
                                        .font(.system(size: 100))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 420)

                    // Right Column: Title, Singer Details, Playback Controls & Drawer
                    VStack(alignment: .leading, spacing: 20) {
                        // Track & Artist Information
                        VStack(alignment: .leading, spacing: 8) {
                            Text(self.song?.title ?? "No Track Playing")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .lineLimit(2)
                                .foregroundStyle(.primary)

                            // Singer / Artists
                            HStack(spacing: 8) {
                                Image(systemName: "person.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.tint)

                                Text(self.song?.artists.map(\.name).joined(separator: ", ") ?? "Unknown Artist")
                                    .font(.title2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            if let albumTitle = self.song?.album?.title {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.stack.fill")
                                        .font(.subheadline)
                                        .foregroundStyle(.tertiary)

                                    Text(albumTitle)
                                        .font(.headline)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                .padding(.top, 2)
                            }
                        }

                        Divider()
                            .padding(.vertical, 4)

                        // Interactive Scrubber & Controls
                        SpotlightControlsSection(
                            isPlaying: self.isPlaying,
                            progress: self.progress,
                            duration: self.duration,
                            volume: self.volume,
                            isMuted: self.isMuted,
                            onPlayPause: self.onPlayPause,
                            onSeek: self.onSeek,
                            onNext: self.onNext,
                            onPrevious: self.onPrevious,
                            onVolumeChange: self.onVolumeChange,
                            onToggleMute: self.onToggleMute
                        )

                        // Drawer Options Toggle Bar (Lyrics & Queue)
                        HStack(spacing: 16) {
                            Button(action: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    if self.isDrawerVisible, self.selectedDrawerTab == .lyrics {
                                        self.isDrawerVisible = false
                                    } else {
                                        self.selectedDrawerTab = .lyrics
                                        self.isDrawerVisible = true
                                    }
                                }
                            }, label: {
                                Label("Lyrics", systemImage: "quote.bubble.fill")
                                    .font(.headline.weight(.medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(self.isDrawerVisible && self.selectedDrawerTab == .lyrics ? Color.accentColor.opacity(0.2) : Color.clear)
                                    .clipShape(Capsule())
                                    .foregroundStyle(self.isDrawerVisible && self.selectedDrawerTab == .lyrics ? Color.accentColor : Color.secondary)
                            })
                            .buttonStyle(.plain)

                            Button(action: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    if self.isDrawerVisible, self.selectedDrawerTab == .queue {
                                        self.isDrawerVisible = false
                                    } else {
                                        self.selectedDrawerTab = .queue
                                        self.isDrawerVisible = true
                                    }
                                }
                            }, label: {
                                Label("Up Next (\(self.queueSongs.count))", systemImage: "list.bullet.rectangle.portrait.fill")
                                    .font(.headline.weight(.medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(self.isDrawerVisible && self.selectedDrawerTab == .queue ? Color.accentColor.opacity(0.2) : Color.clear)
                                    .clipShape(Capsule())
                                    .foregroundStyle(self.isDrawerVisible && self.selectedDrawerTab == .queue ? Color.accentColor : Color.secondary)
                            })
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 4)

                        // Embedded Lyrics / Queue Panel if active
                        if self.isDrawerVisible {
                            SpotlightSideDrawer(
                                selectedTab: self.$selectedDrawerTab,
                                isVisible: self.isDrawerVisible,
                                lyricsText: self.lyricsText,
                                queueSongs: self.queueSongs
                            )
                            .frame(maxHeight: 220)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .frame(maxWidth: 480)
                }
                .padding(.horizontal, 40)

                Spacer(minLength: 24)
            }
        }
        .frame(minWidth: 880, minHeight: 600)
    }
}
