import SwiftUI

/// Player bar shown at the bottom of the content area, styled like Apple Music with Liquid Glass.
@available(macOS 26.0, *)
struct PlayerBar: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(WebKitManager.self) private var webKitManager

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                // Left section: Playback controls
                playbackControls

                Spacer()

                // Center section: Thumbnail + Now playing info
                centerSection

                Spacer()

                // Right section: Volume control
                volumeControl
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(height: 52)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        HStack(spacing: 20) {
            // Previous
            Button {
                Task {
                    await playerService.previous()
                }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous track")

            // Play/Pause
            Button {
                Task {
                    await playerService.playPause()
                }
            } label: {
                Image(systemName: playerService.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playerService.isPlaying ? "Pause" : "Play")

            // Next
            Button {
                Task {
                    await playerService.next()
                }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next track")
        }
    }

    // MARK: - Center Section

    private var centerSection: some View {
        HStack(spacing: 10) {
            // Thumbnail
            AsyncImage(url: playerService.currentTrack?.thumbnailURL?.highQualityThumbnailURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Track info
            if let track = playerService.currentTrack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Text(track.artistsDisplay.isEmpty ? "Unknown Artist" : track.artistsDisplay)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 200, alignment: .leading)
            }
        }
    }

    // MARK: - Volume Control

    private var volumeControl: some View {
        HStack(spacing: 6) {
            Image(systemName: volumeIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.6))
                .frame(width: 16)

            Slider(
                value: Binding(
                    get: { playerService.volume },
                    set: { newValue in
                        Task {
                            await playerService.setVolume(newValue)
                        }
                    }
                ),
                in: 0 ... 1
            )
            .frame(width: 80)
            .controlSize(.small)
        }
    }

    private var volumeIcon: String {
        if playerService.volume == 0 {
            "speaker.slash.fill"
        } else if playerService.volume < 0.5 {
            "speaker.wave.1.fill"
        } else {
            "speaker.wave.2.fill"
        }
    }
}

@available(macOS 26.0, *)
#Preview {
    PlayerBar()
        .environment(PlayerService())
        .environment(WebKitManager.shared)
        .frame(width: 600)
        .padding()
        .background(.black)
}
